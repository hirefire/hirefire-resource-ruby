# frozen_string_literal: true

module HireFire
  class Sampler
    def initialize(configuration)
      @configuration = configuration
      @once = Once.new(configuration)
    end

    def can_sample?(plan)
      @configuration.job_queues.any? || plan.any? { |raw| Plan::Entry.new(raw).sampleable? }
    end

    def round(plan, live)
      probe = Probe.start
      Plan.around_job_queue_sample(logger) do
        plan.each do |raw|
          break unless live.call

          probe.measure(raw) { sample(Plan::Entry.new(raw), live) }
        end
      end
      probe.log_to(logger) if Log.verbose?
      probe.finish
    end

    private

    def sample(entry, live)
      if entry.problem
        @once.log(:error, entry.problem, entry.key) { "[HireFire] #{entry.problem_message}" }
      elsif entry.local?
        sample_local(entry, live)
      else
        sample_adapter(entry, live)
      end
    rescue StandardError, ScriptError => e
      Log.safe(logger, :error, "[HireFire] Plan sampler for #{entry.name.inspect} raised #{Log.format_error(e)}")
    end

    def sample_local(entry, live)
      job_queue = @configuration.job_queues.find_by_name(entry.name)
      if job_queue
        record("The sampler", entry.name, entry.strategy, live) { job_queue.sample }
      elsif @configuration.job_queues.any?
        @once.log(:warn, :no_local_sampler, entry.name) do
          "[HireFire] No config.dyno sampler is named #{entry.name.inspect}, so this process " \
            "samples nothing for it. Check the name, or select an adapter for it in the HireFire UI."
        end
      end
    end

    def sample_adapter(entry, live)
      if @configuration.job_queues.find_by_name(entry.name)
        @once.log(:warn, :plan_override, entry.name) do
          "[HireFire] A HireFire UI adapter is configured for #{entry.name.inspect}, so " \
            "config.dyno(#{entry.name.inspect}) with a local sampler is ignored. You can remove that " \
            "local configuration. The UI adapter is used instead."
        end
      end
      if entry.truncated?
        @once.log(:error, :queues_truncated, entry.name) do
          "[HireFire] Plan queue list for #{entry.name.inspect} truncated to #{Plan::MAX_QUEUES} names."
        end
      end

      record("Plan sampler", entry.name, entry.strategy, live) { entry.call }
      record("Plan working sampler", entry.name, Strategy::WRK, live) { entry.working } if entry.working?
    end

    def record(label, name, strategy, live)
      value = yield
      return unless live.call

      if Sample.valid?(value)
        @configuration.buffer.sample(name, strategy, Sample.coerce(value))
      else
        Log.safe(logger, :error, "[HireFire] #{label} for #{name.inspect} returned " \
          "#{Sample.format(value)}, expected a non-negative number. Sample dropped.")
      end
    rescue StandardError, ScriptError => e
      Log.safe(logger, :error, "[HireFire] #{label} for #{name.inspect} raised #{Log.format_error(e)}")
    end

    def logger
      @configuration.logger
    end
  end
end
