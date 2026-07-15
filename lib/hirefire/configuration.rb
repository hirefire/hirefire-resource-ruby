# frozen_string_literal: true

require "logger"

module HireFire
  # Declares what each process tracks (http, job metrics, CPU) and holds shared settings such as
  # the token and logger.
  #
  # @!attribute [r] web
  #   The http collector once an http process is declared, otherwise +nil+.
  #   @return [HireFire::Web, nil]
  # @!attribute [r] workers
  #   Job-metric collectors declared via sampler blocks on {#service} or {#dyno}.
  #   @return [HireFire::Workers]
  # @!attribute [r] cpu
  #   CPU collectors declared via {#service} or {#dyno} with +tracking: :cpu+.
  #   @return [Array<HireFire::CPU>]
  # @!attribute [rw] logger
  #   Logger used for HireFire diagnostic messages. Defaults to a stdout logger. Set to +nil+
  #   (or a logger missing the log methods) to silence diagnostics.
  #   @return [#error, #warn, #info, nil]
  # @!attribute [rw] log_queue_metrics
  #   When true, the HTTP middleware prints +[hirefire:router] queue=…ms+ for each sample.
  #   @return [Boolean]
  class Configuration
    # Raised when {#service} or {#dyno} cannot resolve a collector because neither +tracking+ nor a
    # sampler block was given. Bare +dyno(:web)+ is valid: the +"web"+ name implies http without
    # either argument.
    class MissingSamplerError < StandardError; end

    # Raised when a sampler block is given alongside +tracking: :http+ or +tracking: :cpu+, which
    # collect their values automatically and do not take a sampler.
    class UnexpectedSamplerError < StandardError; end

    # Raised when +tracking+ is given a value the method does not accept.
    class UnknownCollectorError < StandardError; end

    # Raised when a dyno name was already declared (names are compared case-insensitively), or a
    # second http process is declared in the same app process.
    class DuplicateDynoError < StandardError; end

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

    # The HireFire API token. Returns the value assigned in code when it is not +nil+, else the
    # +HIREFIRE_TOKEN+ environment variable, else +nil+. Assigning +nil+ clears the in-code value so
    # the environment variable is consulted again. It does not force the token off when
    # +HIREFIRE_TOKEN+ is set. A token present when {HireFire.configure} runs starts the dispatcher
    # and enables reporting.
    #
    # @return [String, nil]
    def token
      @token || ENV["HIREFIRE_TOKEN"]
    end

    # Declares a service by dyno name. Like {#service}, but the name "web" (case-insensitive)
    # implies `tracking: :http` on its own, and `:cpu` is the only `tracking:` value it accepts.
    #
    # Resolution: `tracking: :cpu` tracks CPU, a sampler block tracks job metrics, and the name "web"
    # (case-insensitive) tracks http on its own. For an http process under a non-"web" name, use
    # `service(name, tracking: :http)`.
    #
    # @param name [String, Symbol] the process name. Must be non-empty.
    # @param tracking [Symbol, String, nil] `:cpu`, or omit.
    # @yield a sampler returning the current job-queue metric (a non-negative, finite number).
    # @return [void]
    # @raise [ArgumentError] the name is empty.
    # @raise [MissingSamplerError] a non-"web" name given with neither `tracking: :cpu` nor a sampler.
    # @raise [UnexpectedSamplerError] a sampler given alongside `tracking: :cpu`.
    # @raise [UnknownCollectorError] `tracking:` given anything other than `:cpu`.
    # @raise [DuplicateDynoError] the name was already declared, or a second http process was declared.
    # @example
    #   config.dyno(:web) # "web" implies http
    #   config.dyno(:worker) { HireFire::Macro::Sidekiq.job_queue_size(:default) }
    #   config.dyno(:encoder, tracking: :cpu)
    def dyno(name, tracking: nil, &sampler)
      name = coerce_name!(name)

      collector =
        if tracking
          DYNO_COLLECTORS.fetch(tracking.to_s.to_sym) do
            raise UnknownCollectorError,
              "Unknown value #{tracking.inspect} for config.dyno(:#{name}, tracking: ...). " \
              "config.dyno only tracks :cpu. Pass a sampler block for job metrics, " \
              "or use config.service to track :http explicitly."
          end
        elsif sampler
          :job
        elsif name.casecmp?("web")
          :http
        else
          raise MissingSamplerError,
            "config.dyno(:#{name}) could not be resolved: it needs a sampler block " \
            "(job metrics) or tracking: :cpu. Only the \"web\" name implies http on its own. " \
            "Use config.service(:#{name}, tracking: :http) for an http process under another name."
        end

      register(name, collector, &sampler)
    end

    # Declares what a process tracks. The name is a label with no implicit meaning, so what to
    # track is always explicit. Pass exactly one of `tracking:` or a sampler block:
    #
    # - `tracking: :http`: web request queue-time metrics, sampled from this process's own HTTP
    #   traffic by the framework middleware (at most one http process per app process).
    # - a sampler block returning the current value: job queue metrics, typically via a queue
    #   macro (e.g. `HireFire::Macro::Sidekiq.job_queue_latency`).
    # - `tracking: :cpu`: this process's CPU utilization.
    #
    # {#dyno} is this method plus the convention that the name "web" implies `:http`.
    #
    # @param name [String, Symbol] the process name. Must be non-empty.
    # @param tracking [Symbol, String, nil] `:http` or `:cpu`. Omit when passing a sampler.
    # @yield a sampler returning the current job-queue metric (a non-negative, finite number).
    # @return [void]
    # @raise [ArgumentError] the name is empty.
    # @raise [MissingSamplerError] neither `tracking:` nor a sampler was given.
    # @raise [UnexpectedSamplerError] a sampler given alongside `tracking: :http` or `:cpu`.
    # @raise [UnknownCollectorError] `tracking:` given an unsupported value.
    # @raise [DuplicateDynoError] the name was already declared, or a second http process was declared.
    # @example
    #   config.service(:web, tracking: :http)
    #   config.service(:worker) { HireFire::Macro::Sidekiq.job_queue_size(:default) }
    #   config.service(:encoder, tracking: :cpu)
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

    # In-memory metric buffer that accumulates samples between dispatcher flushes.
    #
    # @return [HireFire::Buffer]
    def buffer
      @buffer || @mutex.synchronize { @buffer ||= Buffer.new }
    end

    # Periodic reporter that samples workers/CPU and flushes buffered metrics to the API.
    #
    # @return [HireFire::Dispatcher]
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

    # Stops the dispatcher if one was started.
    #
    # @return [void]
    def stop_dispatcher
      @dispatcher&.stop
    end

    private

    def coerce_name!(name)
      name = name.to_s

      if name.empty?
        raise ArgumentError,
          "config.dyno and config.service require a dyno name as their first " \
          "argument (got #{name.inspect})."
      end

      name
    end

    def register(name, collector, &sampler)
      if @names.any? { |existing| existing.casecmp?(name) }
        raise DuplicateDynoError,
          "Duplicate declaration for #{name.inspect}. " \
          "Each dyno name maps to exactly one collector."
      end

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
        @workers << Worker.new(name, &sampler)
      when :cpu
        reject_sampler!(name, sampler)
        @cpu << CPU.new(name)
      end

      @names << name
    end

    def reject_sampler!(name, sampler)
      return unless sampler

      raise UnexpectedSamplerError,
        "#{name.inspect} does not take a sampler block " \
        "(its values are collected automatically)."
    end

    def active_cpu_collectors
      return [] if @cpu.empty?

      identity = resolved_identity

      if identity.nil?
        Log.safe(logger, :error, "[HireFire] CPU metrics are configured but this process's identity " \
          "could not be resolved, so the CPU collector is disabled. Set the " \
          "HIREFIRE_SERVICE_NAME environment variable to this process's dyno name.")
        return []
      end

      @cpu.select { |collector| collector.name.casecmp?(identity) }
    end

    def web_liveness?
      return true unless @web

      identity = resolved_identity
      identity.nil? || identity.casecmp?(@web.name)
    end

    def resolved_identity
      return @resolved_identity if defined?(@resolved_identity)

      if HireFire::Identity.heroku_conflict?
        Log.safe(logger, :warn, "[HireFire] HIREFIRE_SERVICE_NAME (#{HireFire::Identity.explicit}) does not " \
          "match the Heroku DYNO prefix (#{HireFire::Identity.heroku_dyno}). Heroku config vars " \
          "are app-wide, so this makes every dyno identify as the same name. Set it inline per " \
          "process in the Procfile, or unset it to use automatic detection.")
      end

      @resolved_identity = HireFire::Identity.resolve
    end
  end
end
