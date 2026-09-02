# frozen_string_literal: true

require "logger"

module HireFire
  class Configuration
    class MissingSamplerError < StandardError; end

    class DuplicateDynoError < StandardError; end

    attr_reader :http, :job_queues, :log_queue_metrics, :logger
    attr_writer :token

    MAX_NAME_BYTES = 128

    def initialize
      @http = nil
      @job_queues = Source::JobQueues.new(self)
      @sources_by_name = {}
      @buffer = nil
      @dispatcher = nil
      @logger = Logger.new($stdout)
      @default_logger = true
      @token = nil
      @log_queue_metrics = false
      @mutex = Mutex.new
      @always_on_cpu = nil
      @always_on_http = nil
      @http_active = false
    end

    def logger=(value)
      @logger = value
      @default_logger = false
    end

    def using_default_logger?
      @default_logger
    end

    def log_queue_metrics=(value)
      @log_queue_metrics = !!value
      warn_log_queue_metrics_once if @log_queue_metrics
    end

    def token
      value = @token.nil? ? ENV["HIREFIRE_TOKEN"] : @token
      return nil if value.nil?

      value = value.to_s.strip
      value unless value.empty?
    end

    def dyno(name, &sampler)
      name = coerce_name!(name)

      if sampler
        register(name, :job_queue, &sampler)
        return
      end

      if name.casecmp?("web")
        warn_bare_web_dyno_once
        return
      end

      raise MissingSamplerError,
        "config.dyno(#{name.inspect}) could not be resolved: it needs a sampler block " \
        "(job-queue metrics). Request queue time is always-on via platform web role or " \
        "middleware traffic. CPU is always-on when process identity resolves. " \
        "Bare config.dyno(:web) is a no-op and can be removed."
    end

    def buffer
      @buffer || @mutex.synchronize { @buffer ||= Buffer.new }
    end

    def dispatcher
      @dispatcher || @mutex.synchronize { @dispatcher ||= Dispatcher.new }
    end

    def stop_dispatcher(flush: true)
      @dispatcher&.stop(flush: flush)
    end

    def http_name
      soft_identity
    end

    def mark_http_active!
      @http_active = true
    end

    def rqt_enabled?
      @http_active || HireFire::Identity.platform_http_role?
    end

    def http_source
      name = http_name
      if name.nil?
        warn_rqt_unresolved_once if token && (@http_active || HireFire::Identity.platform_http_role?)
        return nil
      end

      if @always_on_http.nil? || !@always_on_http.name.casecmp?(name)
        @always_on_http = Source::HTTP.new(name)
      end
      @always_on_http
    end

    def rqt_liveness?
      rqt_enabled? && !soft_identity.nil?
    end

    def active_cpu_sources
      identity = soft_identity
      if identity.nil?
        warn_cpu_unresolved_once
        return []
      end

      if @always_on_cpu.nil? || !@always_on_cpu.name.casecmp?(identity)
        @always_on_cpu = Source::CPU.new(identity)
      end
      [@always_on_cpu]
    end

    def reset_after_fork
      @always_on_cpu = nil
      @always_on_http = nil
    end

    def prefork_web_handoff?
      rqt_enabled?
    end

    private

    def coerce_name!(name)
      name = name.to_s.strip

      if name.empty?
        raise ArgumentError,
          "config.dyno requires a dyno name as its first argument (got #{name.inspect})."
      end

      if name.bytesize > MAX_NAME_BYTES
        raise ArgumentError,
          "config.dyno name exceeds #{MAX_NAME_BYTES} bytes (got #{name.bytesize})."
      end

      name
    end

    def register(name, source, &sampler)
      key = name.downcase
      kinds = @sources_by_name[key] || []

      if kinds.include?(source)
        raise DuplicateDynoError,
          "Duplicate declaration for #{name.inspect}. " \
          "Each dyno name maps to at most one source of each kind."
      end

      if source == :job_queue
        @job_queues << Source::JobQueue.new(name, &sampler)
      end

      @sources_by_name[key] = kinds + [source]
    end

    def soft_identity
      warn_heroku_conflict_once
      name = HireFire::Identity.resolve
      return if name.nil?
      return name if name.bytesize <= MAX_NAME_BYTES

      warn_identity_name_too_long_once(name)
      nil
    end

    def warn_identity_name_too_long_once(name)
      return if defined?(@identity_name_too_long_warned)

      @identity_name_too_long_warned = true
      Log.safe(logger, :error, "[HireFire] Process identity exceeds #{MAX_NAME_BYTES} bytes " \
        "(#{name.bytesize}). Metrics under this identity are disabled until the name is shortened.")
    end

    def warn_bare_web_dyno_once
      return if defined?(@bare_web_dyno_warned)

      @bare_web_dyno_warned = true
      Log.safe(logger, :warn, "[HireFire] config.dyno(:web) is deprecated. It does nothing. " \
        "Request queue time is sampled automatically from HTTP traffic. You can remove this " \
        "line. Leaving it does not break anything.")
    end

    def warn_log_queue_metrics_once
      return if defined?(@log_queue_metrics_warned)

      @log_queue_metrics_warned = true
      Log.safe(logger, :warn, "[HireFire] config.log_queue_metrics is deprecated. Stdout " \
        "[hirefire:router] lines still emit while this flag is set. Switch to HireFire " \
        "Request Queue Time: install hirefire-resource 2.0.0 or newer, remove this " \
        "log_queue_metrics = true line, in the HireFire UI change Logplex - Request Queue " \
        "Time to HireFire - Request Queue Time, and set HIREFIRE_TOKEN in the Heroku env.")
    end

    def warn_rqt_unresolved_once
      return if defined?(@rqt_unresolved_warned)

      @rqt_unresolved_warned = true
      Log.safe(logger, :warn, "[HireFire] Request queue time samples dropped: process identity " \
        "is unresolved. Set HIREFIRE_SERVICE_NAME or DYNO.")
    end

    def warn_heroku_conflict_once
      return if defined?(@heroku_conflict_warned)
      return unless HireFire::Identity.heroku_conflict?

      @heroku_conflict_warned = true
      Log.safe(logger, :warn, "[HireFire] HIREFIRE_SERVICE_NAME (#{HireFire::Identity.explicit}) does not " \
        "match the Heroku DYNO prefix (#{HireFire::Identity.heroku_dyno}). Heroku config vars " \
        "are app-wide, so this makes every dyno identify as the same name. Set it inline per " \
        "process in the Procfile, or unset it to use automatic detection.")
    end

    def warn_cpu_unresolved_once
      return if defined?(@cpu_unresolved_warned)

      @cpu_unresolved_warned = true
      Log.safe(logger, :warn, "[HireFire] CPU metrics disabled: process identity is unresolved. " \
        "Set HIREFIRE_SERVICE_NAME or DYNO.")
    end
  end
end
