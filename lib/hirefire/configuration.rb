# frozen_string_literal: true

require "logger"

module HireFire
  class Configuration
    class MissingSamplerError < StandardError; end

    class UnexpectedSamplerError < StandardError; end

    class UnknownStrategyError < StandardError; end

    class DuplicateDynoError < StandardError; end

    # The five public strategy acronyms map to three internal collectors. Within
    # a family the collector is identical: :rqt/:rpm share the http feed and
    # :jql/:jqs share the job feed (the user's block picks the macro), so only
    # the collector kind matters past configuration.
    STRATEGIES = {
      rqt: :http,
      rpm: :http,
      jql: :job,
      jqs: :job,
      cpu: :cpu
    }.freeze

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

    # Declares one dyno's metric strategy. The second argument is the strategy
    # acronym; a name maps 1:1 to exactly one strategy, so declaring the same
    # name twice raises (this is what makes mixing metric kinds under one name
    # structurally impossible). :jql/:jqs require a sampler block (the user's
    # macro call); :rqt/:rpm/:cpu reject one (their values are collected for you).
    def dyno(name, strategy, &sampler)
      name = name.to_s

      if name.empty?
        raise ArgumentError,
          "config.dyno requires a dyno name as its first argument (got #{name.inspect})."
      end

      collector = STRATEGIES.fetch(strategy.to_s.to_sym) do
        raise UnknownStrategyError,
          "Unknown strategy #{strategy.inspect} for config.dyno(:#{name}, ...). " \
          "Expected one of: #{STRATEGIES.keys.map(&:inspect).join(", ")}."
      end

      # Case-insensitive, matching the identity gates: two names differing only
      # in case would both match one process identity and emit under two names.
      if @names.any? { |existing| existing.casecmp?(name) }
        raise DuplicateDynoError,
          "Duplicate declaration for config.dyno(:#{name}, ...). " \
          "Each dyno name maps to exactly one strategy."
      end
      @names << name

      case collector
      when :http
        reject_sampler!(name, strategy, sampler)
        if @web
          raise DuplicateDynoError,
            "config.dyno(:#{name}, :#{strategy}) conflicts with the earlier http declaration " \
            "for #{@web.name.inspect}. Request metrics are collected from this process's own " \
            "http traffic, so only one :rqt/:rpm dyno can be declared."
        end
        @web = Web.new(name: name)
      when :job
        raise MissingSamplerError, "Missing sampler for config.dyno(:#{name}, :#{strategy}) { ... }" unless sampler
        @workers << Worker.new(name, &sampler)
      when :cpu
        reject_sampler!(name, strategy, sampler)
        @cpu << CPU.new(name)
      end
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

    def reject_sampler!(name, strategy, sampler)
      return unless sampler

      raise UnexpectedSamplerError,
        "config.dyno(:#{name}, :#{strategy}) does not take a sampler block " \
        "(its values are collected automatically)."
    end

    # The CPU collectors that should run in this process. CPU is intrinsic to a
    # process's own dyno, so a collector only runs where the process identity
    # matches its declared name (a worker dyno must not report CPU under "web").
    # This is a hard gate: unresolved identity disables CPU with a loud log line
    # rather than raising — a metrics library must not crash the host app — and
    # the server's missing_metric issue then names the autoscaler.
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
    # under the http collector's name. Real request samples self-gate — only the
    # HTTP-serving process receives requests — but liveness claims do not: any
    # process running the shared initializer would otherwise claim "web alive,
    # zero traffic" seconds, letting idle worker/one-off/console processes
    # satisfy an additive metric's coverage check while the actual web dynos
    # are down. Soft gate: a resolved identity must match the declared name;
    # an unresolved identity allows the claims (http must keep working without
    # a resolver, unlike the cpu collector's hard gate).
    def web_liveness?
      return true unless @web

      identity = resolved_identity
      identity.nil? || identity.casecmp?(@web.name)
    end

    # Memoized so the dispatcher's gates share one resolution, and the Heroku
    # app-wide config var footgun is warned about once: config vars apply to
    # every dyno, so a dashboard-set HIREFIRE_SERVICE_NAME makes all processes
    # identify as the same name. Both gates compare identity to declared names
    # case-insensitively: platforms don't preserve casing consistently (a
    # "Worker:" Procfile entry yields DYNO "Worker.1" on Cedar but a lowercased
    # "worker-..." pod name on Fir).
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
