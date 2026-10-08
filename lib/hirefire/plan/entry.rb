# frozen_string_literal: true

module HireFire
  module Plan
    class Entry
      METHODS = {
        Strategy::JQL => :job_queue_latency,
        Strategy::JQS => :job_queue_size
      }.freeze

      PROBLEMS = {
        unknown_strategy: "Unknown plan strategy %<strategy>p for %<name>p. Entry skipped.",
        unknown_adapter: "Unknown plan adapter %<adapter>p for %<name>p. Entry skipped.",
        unloaded_adapter: "Plan adapter %<adapter>p for %<name>p is not loaded in this process. Entry skipped.",
        unsupported_strategy: "Plan adapter %<adapter>p does not support strategy %<strategy>p for %<name>p. Entry skipped.",
        queues_required: "Plan adapter %<adapter>p for %<name>p requires named queues. Entry skipped.",
        queues_not_a_list: "Plan queues for %<name>p must be an array. Entry skipped.",
        no_valid_queues: "Plan queue list for %<name>p had no valid names. Entry skipped."
      }.freeze

      attr_reader :name, :strategy, :adapter

      def initialize(raw)
        @raw = raw
        @name = raw["name"].to_s
        @strategy = raw["strategy"].to_s
        @adapter = raw["adapter"].to_s
        @macro = ADAPTERS[@adapter]
      end

      def local?
        @adapter.empty?
      end

      def sampleable?
        !local? && problem.nil?
      end

      def problem
        return @problem if defined?(@problem)

        @problem = local? ? local_problem : adapter_problem
      end

      def problem_message
        format(PROBLEMS.fetch(problem), name: @name, strategy: @strategy, adapter: @adapter)
      end

      def key
        [@name, @adapter, @strategy]
      end

      def queues
        valid_queues.first(MAX_QUEUES)
      end

      def truncated?
        valid_queues.size > MAX_QUEUES
      end

      def call
        @macro.public_send(METHODS.fetch(@strategy), *queues, **options)
      end

      def working?
        @macro.respond_to?(:job_queue_working) && (@strategy == Strategy::JQL || options[:skip_working] == true)
      end

      def working
        @macro.job_queue_working(*queues)
      end

      private

      def local_problem
        :unknown_strategy unless METHODS.key?(@strategy)
      end

      def adapter_problem
        return :unknown_adapter unless @macro
        return :unloaded_adapter unless @macro.library_loaded?
        return :unsupported_strategy unless @macro.supports_plan_strategy?(@strategy)
        return :queues_required if @macro.queues_required? && valid_queues.empty?

        listed = @raw["queues"]
        return :queues_not_a_list unless listed.nil? || listed.is_a?(Array)

        :no_valid_queues if valid_queues.empty? && !listed.to_a.empty?
      end

      def options
        @options ||= @macro.plan_options(@strategy, @raw["options"]).merge(@macro.plan_connection_options)
      end

      def valid_queues
        @valid_queues ||= Array(@raw["queues"].is_a?(Array) ? @raw["queues"] : nil).filter_map do |queue|
          name = queue.to_s.strip
          name unless name.empty? || name.bytesize > MAX_QUEUE_NAME_BYTES
        end
      end
    end
  end
end
