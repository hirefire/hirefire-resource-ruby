# frozen_string_literal: true

require "logger"

module HireFire
  # Holds process-wide settings (token, logger) and optional local declarations via {#dyno}.
  #
  # Always-on sources (request queue time on the HTTP middleware path, and CPU when process
  # identity resolves) do not require an explicit {#dyno} declaration. Local job-queue sampler
  # blocks remain the escape hatch for custom probes and legacy root installs until lease plans
  # cover them fully.
  #
  # @!attribute [r] http
  #   The explicit HTTP source once declared via {#dyno}(:"web"), otherwise +nil+. Always-on RQT
  #   still reports under {#http_name} when no explicit HTTP source is set.
  #   @return [HireFire::Source::HTTP, nil]
  # @!attribute [r] job_queues
  #   Local job-queue sources declared via sampler blocks on {#dyno}.
  #   @return [HireFire::Source::JobQueues]
  # @!attribute [rw] logger
  #   Logger used for HireFire diagnostic messages. Defaults to a stdout logger. Set to +nil+
  #   (or a logger missing the log methods) to silence diagnostics.
  #   @return [#error, #warn, #info, nil]
  # @!attribute [rw] log_queue_metrics
  #   When true, the HTTP middleware prints +[hirefire:router] queue=…ms+ for each sample.
  #   @return [Boolean]
  class Configuration
    # Raised when {#dyno} cannot resolve a source because a non-+"web"+ name was given without a
    # sampler block. Bare +dyno(:web)+ is valid: the +"web"+ name implies http without a block.
    class MissingSamplerError < StandardError; end

    # Raised when a dyno name was already declared for the same source kind (names are compared
    # case-insensitively), or a second http process is declared in the same app process.
    class DuplicateDynoError < StandardError; end

    attr_reader :http, :job_queues, :log_queue_metrics, :logger
    attr_writer :token, :log_queue_metrics

    def initialize
      @http = nil
      @job_queues = Source::JobQueues.new
      @sources_by_name = {}
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

    # Assign a logger. +nil+ silences diagnostics (same as a logger missing log methods).
    #
    # @param value [#error, #warn, #info, nil]
    # @return [void]
    def logger=(value)
      @logger = value
      @default_logger = false
    end

    # True until {#logger=} has been called (railtie may replace the stdout default).
    #
    # @return [Boolean]
    def using_default_logger?
      @default_logger
    end

    # The HireFire API token. Returns the value assigned in code when it is not +nil+, else the
    # +HIREFIRE_TOKEN+ environment variable, else +nil+. An empty string (in code or from the env)
    # is treated as absent (+nil+), so it neither enables reporting nor is sent on the wire.
    # Assigning +nil+ clears the in-code value so the environment variable is consulted again.
    # Assigning an empty string forces the token off even when +HIREFIRE_TOKEN+ is set. A non-empty
    # token present when {HireFire.configure} or {HireFire.boot} runs starts the dispatcher and
    # enables reporting.
    #
    # @return [String, nil]
    def token
      value = @token.nil? ? ENV["HIREFIRE_TOKEN"] : @token
      return nil if value.nil?

      value = value.to_s.strip
      value unless value.empty?
    end

    # Declares a process by dyno name (Heroku Procfile-shaped). No +tracking:+ keyword: CPU is
    # always-on when identity resolves, and RQT is armed by platform web role, middleware traffic,
    # or the +"web"+ name convention below.
    #
    # Resolution: a sampler block tracks job-queue metrics (+jql+ / +jqs+). The name +"web"+
    # (case-insensitive) tracks http on its own. Otherwise a sampler is required.
    #
    # Prefer zero-config ({HireFire.boot} / railtie + token) for request queue time, CPU, and
    # lease-driven job-queue metrics. Use {#dyno} for local job-queue sampler blocks (custom probes, legacy
    # root) and optional explicit +web+ http registration.
    #
    # @param name [String, Symbol] the process name. Must be non-empty.
    # @yield a sampler returning the current job-queue metric (a non-negative, finite number).
    # @return [void]
    # @raise [ArgumentError] the name is empty.
    # @raise [MissingSamplerError] a non-"web" name given without a sampler.
    # @raise [DuplicateDynoError] the name was already declared for the same source kind, or a
    #   second http process was declared.
    # @example
    #   config.dyno(:web) # optional; "web" implies http (zero-config usually enough)
    #   config.dyno(:worker) { HireFire::Macro::Sidekiq.job_queue_size(:default) }
    def dyno(name, &sampler)
      name = coerce_name!(name)

      source =
        if sampler
          :job_queue
        elsif name.casecmp?("web")
          :http
        else
          raise MissingSamplerError,
            "config.dyno(:#{name}) could not be resolved: it needs a sampler block " \
            "(job-queue metrics). Only the \"web\" name implies http on its own. " \
            "RQT is always-on via platform web role or middleware traffic; " \
            "CPU is always-on when process identity resolves."
        end

      register(name, source, &sampler)
    end

    # In-memory metric buffer that accumulates samples between dispatcher flushes.
    #
    # @return [HireFire::Buffer]
    def buffer
      @buffer || @mutex.synchronize { @buffer ||= Buffer.new }
    end

    # Periodic reporter that samples job queues and CPU and flushes buffered metrics to the API.
    #
    # @return [HireFire::Dispatcher]
    def dispatcher
      @dispatcher || @mutex.synchronize { @dispatcher ||= Dispatcher.new }
    end

    # Stops the dispatcher if one was started.
    #
    # @param flush [Boolean] forwarded to {HireFire::Dispatcher#stop}
    # @return [void]
    def stop_dispatcher(flush: true)
      @dispatcher&.stop(flush: flush)
    end

    # Process name used for request-queue-time metrics.
    #
    # Prefer an explicit HTTP source name when declared via {#dyno}. Otherwise the resolved
    # process identity. No invented default (e.g. not +"web"+): without a real name there is
    # nothing reliable to report under.
    #
    # @return [String, nil]
    def http_name
      return @http.name if @http

      soft_identity
    end

    # Marks this process as serving HTTP (middleware has sampled). Universal always-on RQT arm
    # for any platform once real traffic is observed.
    #
    # @return [void]
    def mark_http_active!
      @http_active = true
    end

    # Whether this process should emit the +rqt+ wire metric (real samples and/or liveness).
    #
    # Arming layers (any one is enough):
    # 1. **Traffic-first (universal):** middleware has sampled (+mark_http_active!+).
    # 2. **Explicit:** HTTP source declared via {#dyno}(:"web").
    # 3. **Platform role (optional pre-traffic):** Heroku process type +"web"+ (Cedar/Fir
    #    +DYNO+ strip) or Render +RENDER_SERVICE_TYPE=web+. See {HireFire::Identity.platform_http_role?}.
    #
    # Other platforms without a role signal wait for traffic (or explicit +dyno(:web)+). That is
    # intentional and only affects idle heartbeats before the first request.
    #
    # @return [Boolean]
    def rqt_enabled?
      @http || @http_active || HireFire::Identity.platform_http_role?
    end

    # The HTTP source used for sampling, creating an always-on source when none was declared
    # and a report name is known.
    #
    # @return [HireFire::Source::HTTP, nil]
    def http_source
      return @http if @http

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

    # Whether +rqt+ liveness claims (heartbeats and backfill) may be synthesized for this process.
    #
    # Requires RQT arming, a resolved process identity, and that identity matching {#http_name}.
    # Unresolved identity never synthesizes liveness (no guessing).
    #
    # @return [Boolean]
    def rqt_liveness?
      return false unless rqt_enabled?

      identity = soft_identity
      return false if identity.nil? || http_name.nil?

      identity.casecmp?(http_name)
    end

    # Always-on CPU source for this process when identity resolves.
    #
    # Unresolved identity yields no CPU sources (no declaration can enable CPU without
    # identity) and logs once so operators notice missing +HIREFIRE_SERVICE_NAME+ / platform
    # identity env.
    #
    # @return [Array<HireFire::Source::CPU>]
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

    # Drop process-local always-on source instances after a fork so CPU baselines are not
    # inherited from the parent. Called from {HireFire::Dispatcher} on child restart.
    #
    # @return [void]
    def reset_after_fork
      @always_on_cpu = nil
      @always_on_http = nil
    end

    # Whether this process participates in prefork web master → worker handoff on +Process._fork+.
    #
    # True when RQT is armed (platform web role, explicit http dyno, or prior traffic). Job-only
    # processes stay false so Resque-style fork-per-job parents keep reporting and children do not
    # start a short-lived dispatcher.
    #
    # @return [Boolean]
    def prefork_web_handoff?
      rqt_enabled?
    end

    private

    MAX_NAME_BYTES = 128

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

      case source
      when :http
        if @http
          raise DuplicateDynoError,
            "#{name.inspect} conflicts with the earlier http declaration for " \
            "#{@http.name.inspect}. Request metrics are collected from this process's own " \
            "http traffic, so only one HTTP source can be declared, under any name."
        end
        @http = Source::HTTP.new(canonical_name(name))
      when :job_queue
        @job_queues << Source::JobQueue.new(canonical_name(name), &sampler)
      end

      @sources_by_name[key] = kinds + [source]
    end

    def canonical_name(name)
      existing = @sources_by_name.keys.find { |key| key.casecmp?(name) }
      return name unless existing

      [@http&.name, *@job_queues.map(&:name)].compact.find { |n| n.casecmp?(name) } || name
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

    def warn_rqt_unresolved_once
      return if defined?(@rqt_unresolved_warned)

      @rqt_unresolved_warned = true
      Log.safe(logger, :warn, "[HireFire] Request queue time samples dropped: process identity " \
        "is unresolved. Set HIREFIRE_SERVICE_NAME, or rely on DYNO / RENDER_SERVICE_NAME where " \
        "available (or declare config.dyno(:web)).")
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
        "Set HIREFIRE_SERVICE_NAME, or rely on DYNO / RENDER_SERVICE_NAME where available.")
    end
  end
end
