# frozen_string_literal: true

require "logger"

module HireFire
  class Configuration
    class MissingSamplerError < StandardError; end

    class UnexpectedSamplerError < StandardError; end

    class UnknownCollectorError < StandardError; end

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

    def token
      @token || ENV["HIREFIRE_TOKEN"]
    end

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

    # Synchronized double-checked init: concurrent request threads must not build
    # (and start) two buffers/dispatchers.
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
      # Case-insensitive: names differing only in case would gate as one identity.
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

    def web_liveness?
      return true unless @web

      identity = resolved_identity
      identity.nil? || identity.casecmp?(@web.name)
    end

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
