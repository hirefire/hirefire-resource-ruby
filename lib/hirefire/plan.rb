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

    def execute(entry)
      adapter = entry["adapter"].to_s
      strategy = entry["strategy"].to_s
      name = entry["name"].to_s
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

      queues = normalize_queues(entry["queues"])
      options = macro.plan_options(strategy, entry["options"])
        .merge(macro.plan_connection_options)
      value = macro.public_send(method_name, *queues, **options)

      unless valid_sample?(value)
        Log.safe(logger, :error, "[HireFire] Plan sampler for #{name.inspect} returned " \
          "#{value.inspect}, expected a non-negative number. Sample dropped.")
        return
      end

      HireFire.configuration.buffer.sample(name, strategy, coerce_sample(value))
    rescue => e
      Log.safe(logger, :error, "[HireFire] Plan sampler for #{name.inspect} raised " \
        "#{e.class}: #{e.message}")
    end

    private

    def normalize_queues(queues)
      list = Array(queues)
      if list.size > MAX_QUEUES
        Log.safe(logger, :error,
          "[HireFire] Plan queue list truncated to #{MAX_QUEUES} names.")
        list = list.first(MAX_QUEUES)
      end

      list.filter_map do |queue|
        name = queue.to_s.strip
        next if name.empty? || name.bytesize > MAX_QUEUE_NAME_BYTES

        name
      end
    end

    def valid_sample?(value)
      value.is_a?(Numeric) && value.finite? && value >= 0
    end

    def coerce_sample(value)
      (value.is_a?(Integer) || value.is_a?(Float)) ? value : value.to_f
    end

    def logger
      HireFire.configuration.logger
    end
  end
end
