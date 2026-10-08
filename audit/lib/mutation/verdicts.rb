# frozen_string_literal: true

require "prism"

module Audit
  module Mutation
    NIL_INITIALIZER = "the deleted line sets an instance variable to nil or false where the object is built, and an unset instance variable reads nil, which every reader treats the same"
    ONE_ROW = "the query returns one row, so the first row is the last"
    ROUND_MEMORY = "the end of a round clears the walks and the snapshot of running jobs to release their memory. The next round clears them again before it reads, so no result depends on it"

    LOCK_FREE_READ = "the read before the lock is a shortcut. The locked branch returns the same object"
    START_CHECK = "the check before the lock is a shortcut that the locked check repeats, and callers read the result of start as true or not true"

    VERDICTS = [
      {file: "configuration", method: %w[buffer dispatcher], kind: "logical_right", verdict: "equivalent", reason: LOCK_FREE_READ},
      {file: "dispatcher", method: "start", kind: %w[return_nil], verdict: "equivalent", reason: START_CHECK},
      {file: "dispatcher", method: "start", kind: "condition_false", original: "healthy?", verdict: "equivalent", reason: START_CHECK},
      {file: "dispatcher", method: "start", kind: "logical_left", original: "@stopping || healthy?", verdict: "accepted",
       reason: "the health check under the lock closes the race between two starts that both passed the first check. A test cannot stage that race without holding the lock of the dispatcher from outside"},
      {file: "macro/solid_queue", method: "scheduled_latency", kind: "drop_call", verdict: "equivalent",
       reason: "the smallest scheduled time of a queue is the oldest due one whenever one is due, and a smallest time in the future is clamped to zero"},
      {method: "initialize", kind: "delete_statement", original: /\A@\w+ = (nil|false)\z/, verdict: "equivalent", reason: NIL_INITIALIZER},
      {file: "macro/que", kind: "method_swap", original: "first", verdict: "equivalent", reason: ONE_ROW},
      {file: "macro/helpers/good_job", method: "good_job_class", kind: "condition_true", verdict: "accepted",
       reason: "Good Job 3 answers every query of the macro the same through GoodJob::Job and GoodJob::Execution, so no test can tell them apart. The switch follows the Good Job upgrade guide"},
      {file: "macro/queue_classic", method: "query_one", kind: "condition_true", original: "binds.any?", verdict: "equivalent",
       reason: "without binds, sanitize_sql_array returns the statement as it is"},
      {file: "macro/resque", method: "heartbeat_expired?", kind: "return_nil", verdict: "equivalent",
       reason: "the caller is a reject block, which treats nil and false the same"},
      {file: "macro/resque", method: "heartbeat_expired?", kind: "operator", original: ">", verdict: "accepted",
       reason: "the age of a heartbeat is whole seconds against the clock of Redis. A test cannot hold a heartbeat at exactly the prune interval without replacing the Redis client, and one second of a five minute interval does not change which workers count"},
      {file: "macro/sidekiq/due_cache", method: "begin_sample!", kind: "integer", original: "1", verdict: "equivalent",
       reason: "the round number only has to differ from the one before, and a step of two does that as well"},
      {file: "macro/sidekiq/due_cache", method: "end_sample!", kind: "delete_statement", original: /\A@(caches = \{\}|working = nil)\z/, verdict: "accepted", reason: ROUND_MEMORY},
      {file: "macro/sidekiq/due_cache", method: "first_due_age", kind: "method_swap", original: "first", verdict: "equivalent",
       reason: "ZRANGE 0 0 returns one member, so the first is the last"},
      {file: "macro/sidekiq/due_cache", method: "first_due_age", kind: "operator", original: "<=", verdict: "equivalent",
       reason: "a member that is due at this very moment has an age of zero, which is also the answer for a member that is not due"}
    ].freeze

    class MethodRanges < Prism::Visitor
      attr_reader :ranges

      def initialize
        super
        @ranges = []
      end

      def visit_def_node(node)
        @ranges << [node.location.start_line, node.location.end_line, node.name.to_s]
        super
      end
    end

    RANGES = Hash.new do |ranges, path|
      visitor = MethodRanges.new
      visitor.visit(Prism.parse_file(path).value)
      ranges[path] = visitor.ranges
    end

    def self.enclosing_method(root, file, line)
      range = RANGES[File.join(root, file)].select { |first, last, _| line.between?(first, last) }.min_by { |first, last, _| last - first }
      range ? range[2] : "(top level)"
    end

    def self.verdict_index(root, file:, line:, kind:, original:, replacement:)
      name = enclosing_method(root, file, line)
      first = original.lines.first.to_s.strip
      VERDICTS.index do |rule|
        (rule[:file].nil? || file == "lib/hirefire/#{rule[:file]}.rb" || file == rule[:file]) &&
          (rule[:method].nil? || Array(rule[:method]).include?(name)) &&
          (rule[:kind].nil? || Array(rule[:kind]).include?(kind)) &&
          (rule[:original].nil? || rule[:original] === first) &&
          (rule[:replacement].nil? || rule[:replacement] === replacement.lines.first.to_s.strip)
      end
    end
  end
end
