# frozen_string_literal: true

module HireFire
  module Plan
    extend self

    ADAPTERS = {
      "sidekiq" => HireFire::Macro::Sidekiq,
      "solid_queue" => HireFire::Macro::SolidQueue,
      "good_job" => HireFire::Macro::GoodJob,
      "que" => HireFire::Macro::Que,
      "queue_classic" => HireFire::Macro::QC,
      "delayed_job" => HireFire::Macro::Delayed::Job,
      "resque" => HireFire::Macro::Resque,
      "bunny" => HireFire::Macro::Bunny
    }.freeze

    LIBRARY_CHECKS = {
      "sidekiq" => -> { defined?(::Sidekiq) },
      "solid_queue" => -> { defined?(::SolidQueue) },
      "good_job" => -> { defined?(::GoodJob) },
      "que" => -> { defined?(::Que) },
      "queue_classic" => -> { defined?(::QC) },
      "delayed_job" => -> { defined?(::Delayed::Job) },
      "resque" => -> { defined?(::Resque) },
      "bunny" => -> { defined?(::Bunny) }
    }.freeze

    STRATEGIES = {
      "jql" => :job_queue_latency,
      "jqs" => :job_queue_size
    }.freeze

    MAX_QUEUES = 64
    MAX_QUEUE_NAME_BYTES = 128

    def any_allowlisted_job_queue_library_loaded?
      LIBRARY_CHECKS.each_value.any?(&:call)
    end

    def known_adapter?(adapter)
      ADAPTERS.key?(adapter.to_s)
    end

    def library_loaded?(adapter)
      LIBRARY_CHECKS[adapter.to_s]&.call
    end

    def executable?(adapter)
      known_adapter?(adapter) && library_loaded?(adapter)
    end

    def known_strategy?(strategy)
      STRATEGIES.key?(strategy.to_s)
    end

    # Whether the allowlisted adapter can sample +strategy+ when its library is loaded.
    # Used by the dispatcher to skip unsupported pairs (e.g. Bunny/Resque + +jql+) without
    # re-invoking the macro every sample tick.
    #
    # @param adapter [String, Symbol]
    # @param strategy [String, Symbol]
    # @return [Boolean]
    def supports_strategy?(adapter, strategy)
      macro = ADAPTERS[adapter.to_s]
      return false unless macro
      return false unless known_strategy?(strategy)

      macro.supports_plan_strategy?(strategy)
    end

    # Run +block+ as one job-queue sample wave. Every allowlisted macro receives
    # {HireFire::Plan::Hooks#before_sample_job_queues} / +after_sample_job_queues+
    # (defaults no-op). Dispatcher must not know adapter cache details.
    #
    # @yield
    # @return [Object] the block's return value
    def around_job_queue_sample
      tokens = {}
      ADAPTERS.each do |name, macro|
        tokens[name] = macro.before_sample_job_queues
      rescue => e
        Log.safe(logger, :error,
          "[HireFire] before_sample_job_queues for #{name.inspect} raised " \
          "#{e.class}: #{e.message}")
      end

      yield
    ensure
      tokens.each do |name, token|
        ADAPTERS[name].after_sample_job_queues(token)
      rescue => e
        Log.safe(logger, :error,
          "[HireFire] after_sample_job_queues for #{name.inspect} raised " \
          "#{e.class}: #{e.message}")
      end
    end

    # Notify every allowlisted macro after fork / abandoned inherited state.
    # Mirrors buffer reinit sites on the dispatcher.
    #
    # @return [void]
    def reinit_macros_after_fork!
      ADAPTERS.each do |name, macro|
        macro.reinit_after_fork
      rescue => e
        Log.safe(logger, :error,
          "[HireFire] reinit_after_fork for #{name.inspect} raised " \
          "#{e.class}: #{e.message}")
      end
    end

    def execute(entry)
      adapter = entry["adapter"].to_s.strip
      strategy = entry["strategy"].to_s.strip
      name = entry["name"].to_s.strip
      method_name = STRATEGIES[strategy]

      unless method_name
        Log.safe(logger, :error, "[HireFire] Unknown plan strategy #{strategy.inspect} for " \
          "#{name.inspect}. Entry skipped.")
        return
      end

      macro = ADAPTERS[adapter]
      unless macro
        Log.safe(logger, :error, "[HireFire] Unknown plan adapter #{adapter.inspect} for " \
          "#{name.inspect}. Entry skipped.")
        return
      end

      unless macro.supports_plan_strategy?(strategy)
        Log.safe(logger, :error, "[HireFire] Plan adapter #{adapter.inspect} does not support " \
          "strategy #{strategy.inspect} for #{name.inspect}. Entry skipped.")
        return
      end

      queues = normalize_queues(entry["queues"], name: name)
      return if queues.nil?

      options = macro.plan_options(strategy, entry["options"])
        .merge(macro.plan_connection_options)
      return unless sample_job_strategy(macro, name, strategy, method_name, queues, options)

      sample_working(macro, name, queues) if macro.respond_to?(:job_queue_working)
    rescue => e
      Log.safe(logger, :error, "[HireFire] Plan sampler for #{name.inspect} raised " \
        "#{e.class}: #{e.message}")
    end

    private

    # Primary jql/jqs (or other plan strategy) sample. Returns true when a value
    # was buffered so companions like +wrk+ may run.
    def sample_job_strategy(macro, name, strategy, method_name, queues, options)
      value = macro.public_send(method_name, *queues, **options)
      unless valid_sample?(value)
        Log.safe(logger, :error, "[HireFire] Plan sampler for #{name.inspect} returned " \
          "#{format_sample_value(value)}, expected a non-negative number. Sample dropped.")
        return false
      end

      record_sample(name, strategy, value)
      true
    end

    # Companion in-flight series for adapters that implement +job_queue_working+
    # (e.g. Sidekiq). Same queues as the jql/jqs sample. Unconditional (not gated
    # on hold). Failures are logged and do not drop the job strategy sample.
    def sample_working(macro, name, queues)
      wrk = macro.job_queue_working(*queues)
      unless valid_sample?(wrk)
        Log.safe(logger, :error, "[HireFire] Plan working sampler for #{name.inspect} returned " \
          "#{format_sample_value(wrk)}, expected a non-negative number. wrk sample dropped.")
        return
      end

      record_sample(name, "wrk", wrk)
    rescue => e
      Log.safe(logger, :error, "[HireFire] Plan working sampler for #{name.inspect} raised " \
        "#{e.class}: #{e.message}")
    end

    def record_sample(name, strategy, value)
      HireFire.configuration.buffer.sample(name, strategy, coerce_sample(value))
    end

    # Returns an Array of queue names, or +nil+ when the entry must be skipped.
    # Missing / null +queues+ → [] (macro may sample all queues when allow_empty).
    # Non-array, or a non-empty list that filters to empty → skip (do not widen to all).
    def normalize_queues(queues, name:)
      return [] if queues.nil?

      unless queues.is_a?(Array)
        Log.safe(logger, :error,
          "[HireFire] Plan queues for #{name.inspect} must be an array. Entry skipped.")
        return nil
      end

      list = queues.filter_map do |queue|
        qname = queue.to_s.strip
        next if qname.empty? || qname.bytesize > MAX_QUEUE_NAME_BYTES

        qname
      end

      if list.empty? && !queues.empty?
        Log.safe(logger, :error,
          "[HireFire] Plan queue list for #{name.inspect} had no valid names. Entry skipped.")
        return nil
      end

      if list.size > MAX_QUEUES
        Log.safe(logger, :error,
          "[HireFire] Plan queue list truncated to #{MAX_QUEUES} names.")
        list = list.first(MAX_QUEUES)
      end

      list
    end

    def valid_sample?(value)
      value.is_a?(Numeric) && value.finite? && value >= 0
    end

    def coerce_sample(value)
      (value.is_a?(Integer) || value.is_a?(Float)) ? value : value.to_f
    end

    def format_sample_value(value)
      text = value.class.name
      preview = value.to_s
      preview = "#{preview.byteslice(0, 64)}…" if preview.bytesize > 64
      "#{text}(#{preview.inspect})"
    rescue
      value.class.name
    end

    def logger
      HireFire.configuration.logger
    end
  end
end
