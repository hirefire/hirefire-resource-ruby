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
  #   Always +nil+. Kept for readers that still check +configuration.http+. Request queue time
  #   uses always-on sources under {#http_name} (process identity), not an explicit http dyno.
  #   @return [nil]
  # @!attribute [r] job_queues
  #   Local job-queue sources declared via sampler blocks on {#dyno}.
  #   @return [HireFire::Source::JobQueues]
  # @!attribute [rw] logger
  #   Logger used for HireFire diagnostic messages. Defaults to a stdout logger. Set to +nil+
  #   (or a logger missing the log methods) to silence diagnostics.
  #   @return [#error, #warn, #info, nil]
  # @!attribute [rw] log_queue_metrics
  #   Legacy flag: when true, middleware still prints +[hirefire:router] queue=…ms+ to
  #   stdout (Logplex QueueTime BC). Setting true once-warns to migrate to HireFire
  #   Request Queue Time with +HIREFIRE_TOKEN+. Preferred web RQT is push to data.hirefire.io.
  #   @return [Boolean]
  class Configuration
    # Raised when {#dyno} cannot resolve a source because a name was given without a sampler
    # block (except bare +"web"+, which is a no-op for backwards compatibility).
    class MissingSamplerError < StandardError; end

    # Raised when a dyno name was already declared for the same source kind (names are compared
    # case-insensitively).
    class DuplicateDynoError < StandardError; end

    attr_reader :http, :job_queues, :log_queue_metrics, :logger
    attr_writer :token

    def initialize
      @http = nil
      @job_queues = Source::JobQueues.new(self)
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

    # Legacy flag. When true, middleware still prints +[hirefire:router] queue=…ms+
    # to stdout for Logplex QueueTime (1.x BC). Setting true also once-warns to
    # migrate to HireFire Request Queue Time.
    #
    # @param value [Object] truthy enables stdout emit on each measured request
    # @return [void]
    def log_queue_metrics=(value)
      @log_queue_metrics = !!value
      warn_log_queue_metrics_once if @log_queue_metrics
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

    # Declares a process by dyno name (Heroku Procfile-shaped).
    #
    # A sampler block registers a local job-queue source (+jql+ / +jqs+ under the lease plan
    # strategy). Prefer zero-config ({HireFire.boot} / railtie + token) for request queue time
    # and CPU, and lease plan adapters in the HireFire UI for managed job queues. Use {#dyno}
    # with a sampler for custom probes or strategy-only (custom configuration) plan entries.
    #
    # Bare +dyno(:web)+ (no block, name +"web"+ case-insensitive) is accepted for 1.x
    # backwards compatibility but does nothing: RQT is armed only by platform web role and
    # middleware traffic. A once-per-process warning explains that the line can be removed.
    # +dyno(:web) { … }+ still registers a job-queue sampler under the name +"web"+.
    #
    # @param name [String, Symbol] the process name. Must be non-empty.
    # @yield a sampler returning the current job-queue metric (a non-negative, finite number).
    # @return [void]
    # @raise [ArgumentError] the name is empty.
    # @raise [MissingSamplerError] a name other than +"web"+ given without a sampler.
    # @raise [DuplicateDynoError] the name was already declared for the same source kind.
    # @example
    #   config.dyno(:web) # no-op BC; safe to remove
    #   config.dyno(:worker) { HireFire::Macro::Sidekiq.job_queue_size(:default) }
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
        "middleware traffic; CPU is always-on when process identity resolves. " \
        "Bare config.dyno(:web) is a no-op and can be removed."
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
    # Resolved process identity only. No invented default (e.g. not +"web"+): without a real
    # name there is nothing reliable to report under.
    #
    # @return [String, nil]
    def http_name
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
    # 2. **Platform role (optional pre-traffic):** Heroku process type +"web"+ (Cedar/Fir
    #    +DYNO+ strip) or Render +RENDER_SERVICE_TYPE=web+. See {HireFire::Identity.platform_http_role?}.
    #
    # Other platforms without a role signal wait for traffic. That only affects idle heartbeats
    # before the first request.
    #
    # @return [Boolean]
    def rqt_enabled?
      @http_active || HireFire::Identity.platform_http_role?
    end

    # The HTTP source used for sampling, creating an always-on source when a report name is known.
    #
    # @return [HireFire::Source::HTTP, nil]
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
    # True when RQT is armed (platform web role or prior traffic). Job-only processes stay false
    # so Resque-style fork-per-job parents keep reporting and children do not start a short-lived
    # dispatcher.
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

      if source == :job_queue
        @job_queues << Source::JobQueue.new(canonical_name(name), &sampler)
      end

      @sources_by_name[key] = kinds + [source]
    end

    def canonical_name(name)
      existing = @sources_by_name.keys.find { |key| key.casecmp?(name) }
      return name unless existing

      @job_queues.map(&:name).find { |n| n.casecmp?(name) } || name
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
      Log.safe(logger, :warn, "[HireFire] config.dyno(:web) without a sampler is no longer " \
        "necessary. Request queue time is armed by platform web identity (for example DYNO " \
        "type web or RENDER_SERVICE_TYPE=web) and by HTTP middleware traffic. You can remove " \
        "this line.")
    end

    def warn_log_queue_metrics_once
      return if defined?(@log_queue_metrics_warned)

      @log_queue_metrics_warned = true
      Log.safe(logger, :warn, "[HireFire] config.log_queue_metrics is deprecated. Prefer the " \
        "HireFire Request Queue Time strategy, set HIREFIRE_TOKEN, then remove this " \
        "log_queue_metrics = true line. Stdout [hirefire:router] lines still emit while this " \
        "flag is set.")
    end

    def warn_rqt_unresolved_once
      return if defined?(@rqt_unresolved_warned)

      @rqt_unresolved_warned = true
      Log.safe(logger, :warn, "[HireFire] Request queue time samples dropped: process identity " \
        "is unresolved. Set HIREFIRE_SERVICE_NAME, or rely on DYNO / RENDER_SERVICE_NAME where " \
        "available.")
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
