# frozen_string_literal: true

require "logger"

module HireFire
  class Configuration
    class MissingSamplerError < StandardError; end

    class UnexpectedSamplerError < StandardError; end

    class UnknownCollectorError < StandardError; end

    class DuplicateDynoError < StandardError; end

    # The public `tracking:` keyword selects one of three internal collectors.
    # The only value that changes the collector is :cpu; the http and job feeds
    # are each shared by their family (the server derives rqt/rpm from one http
    # feed, and the user's block picks the jql/jqs macro over one job feed), so
    # a single :http value covers the whole HTTP family.
    #
    # service is platform-neutral: the name implies nothing, so http must be
    # named explicitly (tracking: :http) alongside :cpu. dyno is the Heroku
    # convenience: the only value it ever takes is :cpu, because the Procfile
    # "web" name implies http on its own (handled in #dyno, not here).
    SERVICE_COLLECTORS = {http: :http, cpu: :cpu}.freeze
    DYNO_COLLECTORS = {cpu: :cpu}.freeze

    attr_reader :web, :workers, :cpu, :log_queue_metrics
    attr_writer :token, :log_queue_metrics
    attr_accessor :logger

    def initialize
      @web = nil
      @workers = Workers.new
      @cpu = []
      @names = []
      @dispatcher = nil
      @logger = Logger.new($stdout)
      @token = nil
      @log_queue_metrics = false
      @mutex = Mutex.new
    end

    def token
      @token || ENV["HIREFIRE_TOKEN"]
    end

    # Legacy / Heroku front door, backwards-compatible with the 1.x implicit
    # forms. The only thing it ever tracks explicitly is :cpu; the Heroku
    # Procfile convention (the "web" name implies http) is baked in. dyno is
    # exactly #service plus that web ⇒ http convenience.
    #
    #   dyno(:web)                   # http  (1.x form: name "web" implies it)
    #   dyno(:worker) {…}            # job   (1.x form: the block implies it)
    #   dyno(:web, tracking: :cpu)   # cpu on the web process
    #   dyno(:clock, tracking: :cpu) # cpu on a non-web process
    def dyno(name, tracking: nil, &sampler)
      name = coerce_name!(name)

      collector =
        if tracking
          DYNO_COLLECTORS.fetch(tracking.to_s.to_sym) do
            raise UnknownCollectorError,
              "Unknown value #{tracking.inspect} for config.dyno(:#{name}, tracking: ...). " \
              "config.dyno only tracks :cpu; pass a sampler block for job metrics, " \
              "or use config.service to track :http explicitly."
          end
        elsif sampler
          :job
        elsif name.casecmp?("web")
          :http
        else
          raise MissingSamplerError,
            "config.dyno(:#{name}) could not be resolved: it needs a sampler block " \
            "(job metrics) or tracking: :cpu. Only the \"web\" name implies http on its own; " \
            "use config.service(:#{name}, tracking: :http) for an http process under another name."
        end

      register(name, collector, &sampler)
    end

    # Universal / platform-neutral front door. The name carries no meaning, so
    # http must be tracked explicitly with tracking: :http; the block still
    # implies job.
    #
    #   service(:web, tracking: :http)  # http  (any http process name)
    #   service(:worker) {…}            # job   (the block implies it)
    #   service(:clock, tracking: :cpu) # cpu
    def service(name, tracking: nil, &sampler)
      name = coerce_name!(name)

      collector =
        if tracking
          SERVICE_COLLECTORS.fetch(tracking.to_s.to_sym) do
            raise UnknownCollectorError,
              "Unknown value #{tracking.inspect} for config.service(:#{name}, tracking: ...). " \
              "Expected tracking: :http or :cpu, or a sampler block for job metrics."
          end
        elsif sampler
          :job
        else
          raise MissingSamplerError,
            "config.service(:#{name}) could not be resolved: pass tracking: :http, :cpu, " \
            "or a sampler block for job metrics."
        end

      register(name, collector, &sampler)
    end

    # Both memoizations are synchronized: the middleware touches them from
    # concurrent request threads, and an unsynchronized ||= could build (and
    # start) two dispatchers, leaving one running but unreachable.
    def buffer
      @buffer || @mutex.synchronize { @buffer ||= Buffer.new }
    end

    def dispatcher
      @dispatcher || @mutex.synchronize do
        @dispatcher ||= Dispatcher.new(
          web: @web,
          workers: @workers,
          cpu: active_cpu_collectors,
          web_liveness: web_liveness?
        )
      end
    end

    private

    # Coerce the name with to_s (so symbols and strings are interchangeable)
    # and reject an empty result. Shared by both front doors, so the message
    # names both.
    def coerce_name!(name)
      name = name.to_s

      if name.empty?
        raise ArgumentError,
          "config.dyno and config.service require a dyno name as their first " \
          "argument (got #{name.inspect})."
      end

      name
    end

    # Shared back end for both front doors: the duplicate-name guard (spanning
    # dyno and service via the single @names registry) and collector
    # registration. Each front door has already resolved the collector kind and
    # validated its own keyword rules; the per-collector sampler rules (a job
    # needs one, http/cpu reject one) and the one-http-per-process guard live
    # here so they hold identically no matter which front door was used.
    def register(name, collector, &sampler)
      # Case-insensitive, matching the identity gates: two names differing only
      # in case would both match one process identity and emit under two names.
      if @names.any? { |existing| existing.casecmp?(name) }
        raise DuplicateDynoError,
          "Duplicate declaration for #{name.inspect}. " \
          "Each dyno name maps to exactly one collector."
      end
      @names << name

      case collector
      when :http
        reject_sampler!(name, sampler)
        if @web
          raise DuplicateDynoError,
            "#{name.inspect} conflicts with the earlier http declaration for " \
            "#{@web.name.inspect}. Request metrics are collected from this process's own " \
            "http traffic, so only one http collector can be declared, under any name."
        end
        @web = Web.new(name)
      when :job
        raise MissingSamplerError, "Missing sampler for #{name.inspect} { ... }" unless sampler
        @workers << Worker.new(name, &sampler)
      when :cpu
        reject_sampler!(name, sampler)
        @cpu << CPU.new(name)
      end
    end

    def reject_sampler!(name, sampler)
      return unless sampler

      raise UnexpectedSamplerError,
        "#{name.inspect} does not take a sampler block " \
        "(its values are collected automatically)."
    end

    # CPU is intrinsic to a process's own dyno, so a collector only runs where
    # the process identity matches its declared name. Hard gate: unresolved
    # identity disables CPU with a loud log line rather than raising — a
    # metrics library must not crash the host app.
    def active_cpu_collectors
      return [] if @cpu.empty?

      identity = resolved_identity

      if identity.nil?
        logger.error "[HireFire] CPU metrics are configured but this process's identity " \
          "could not be resolved, so the CPU collector is disabled. Set the " \
          "HIREFIRE_SERVICE_NAME environment variable to this process's dyno name."
        return []
      end

      @cpu.select { |collector| collector.name.casecmp?(identity) }
    end

    # Whether this process may synthesize liveness claims (heartbeats/backfill)
    # under the http collector's name. Real request samples self-gate — only
    # the HTTP-serving process receives requests — but without this gate any
    # process running the shared initializer would claim "web alive, zero
    # traffic" seconds while the actual web dynos are down. Soft gate: an
    # unresolved identity still allows the claims, since http must keep working
    # without a resolver.
    def web_liveness?
      return true unless @web

      identity = resolved_identity
      identity.nil? || identity.casecmp?(@web.name)
    end

    # Memoized so the dispatcher's gates share one resolution and the Heroku
    # app-wide config var footgun is warned about once. Identity is compared to
    # declared names case-insensitively because platforms don't preserve casing
    # consistently (a "Worker:" Procfile entry yields DYNO "Worker.1" on Cedar
    # but a lowercased "worker-..." pod name on Fir).
    def resolved_identity
      return @resolved_identity if defined?(@resolved_identity)

      if HireFire::Identity.heroku_conflict?
        logger.warn "[HireFire] HIREFIRE_SERVICE_NAME (#{HireFire::Identity.explicit}) does not " \
          "match the Heroku DYNO prefix (#{HireFire::Identity.heroku_dyno}). Heroku config vars " \
          "are app-wide, so this makes every dyno identify as the same name. Set it inline per " \
          "process in the Procfile, or unset it to use automatic detection."
      end

      @resolved_identity = HireFire::Identity.resolve
    end
  end
end
