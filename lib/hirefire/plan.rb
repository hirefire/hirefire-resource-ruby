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

    MAX_QUEUES = 64
    MAX_QUEUE_NAME_BYTES = 128

    def any_library_loaded?
      ADAPTERS.each_value.any?(&:library_loaded?)
    end

    def around_job_queue_sample(logger)
      tokens = {}
      each_macro(logger, "before_sample_job_queues") do |name, macro|
        tokens[name] = macro.before_sample_job_queues
      end

      yield
    ensure
      each_macro(logger, "after_sample_job_queues") do |name, macro|
        macro.after_sample_job_queues(tokens[name]) if tokens.key?(name)
      end
    end

    def reinit_macros_after_fork(logger)
      each_macro(logger, "reinit_after_fork") { |_name, macro| macro.reinit_after_fork }
    end

    def release_macros(logger)
      each_macro(logger, "release") { |_name, macro| macro.release }
    end

    private

    def each_macro(logger, hook)
      ADAPTERS.each do |name, macro|
        yield name, macro
      rescue => e
        Log.safe(logger, :error, "[HireFire] #{hook} for #{name.inspect} raised #{Log.format_error(e)}")
      end
    end
  end
end
