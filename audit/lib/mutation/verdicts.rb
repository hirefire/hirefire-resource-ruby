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
      {file: "dispatcher", method: "stop", kind: "return_nil", verdict: "equivalent", reason: "callers read the result of stop as true or not true"},
      {file: "dispatcher", method: "stop", kind: "delete_statement", original: "@session = nil", verdict: "accepted",
       reason: "taking the session under the lock closes the race between two stops that both passed the check. A test cannot stage that race without holding the lock of the dispatcher from outside"},
      {file: "dispatcher", method: "abandon_inherited_state!", kind: "delete_statement", original: "@session = nil", verdict: "equivalent",
       reason: "a halted session is not live, so every reader treats it as no session, and the next start replaces it"},
      {file: "dispatcher/session", method: "initialize", kind: "boolean", original: "false", verdict: "equivalent",
       reason: "the handoff flag is read only after a halt, and a halt sets it"},
      {file: "dispatcher/session", method: "alive?", kind: "logical_right", verdict: "accepted",
       reason: "a halted session whose thread has not ended yet is not alive. The dispatcher drops a session in the same step that halts it, so no test reaches that state"},
      {file: "hirefire", method: "handoffs_settled?", kind: "return_nil", verdict: "equivalent", reason: "the watch loop runs until the answer is true, and nil is as untrue as false"},
      {file: "dispatcher/session", method: "encode", kind: "logical_left", verdict: "equivalent",
       reason: "without a trace the second encoding gives the same body, so the check for a trace only saves that work"},
      {file: "lease", method: %w[initialize apply_demote], kind: "integer", original: /\A[01]\z/, verdict: "equivalent",
       reason: "the epoch only has to differ after a demote, so its first value and the size of its step are free"},
      {file: "lease", method: "revoke", kind: "condition_true", verdict: "equivalent",
       reason: "one thread makes the lease requests, so an epoch that moved during a request means a demote, which cleared the grant already"},
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
       reason: "a member that is due at this very moment has an age of zero, which is also the answer for a member that is not due"},
      {file: "macro/sidekiq/due_cache", method: "(top level)", kind: "integer", original: "0", verdict: "equivalent",
       reason: "the round counter only has to rise, so its first value is free"},
      {file: "macro/sidekiq/due_cache", method: "(top level)", kind: "delete_statement", original: /\A@(round = nil|caches = \{\}|working = nil)\z/, verdict: "equivalent",
       reason: "an unset round reads nil, which means no round. The other two are read only inside a round, and the start of a round sets them"},
      {file: "macro/resque", method: "raise_if_walk_budget_exceeded!", kind: "integer", original: "0", verdict: "equivalent",
       reason: "the default serves the delayed walk, which has only a time budget. Zero jobs and one job are both below the job budget"},
      {file: "middleware", method: "present_header", kind: "condition_false", original: "value.nil?", verdict: "equivalent",
       reason: "a header that is not set strips to an empty string, which the next line answers with nil as well. The early return saves a string on the request path"},
      {file: "middleware", method: "calculate_request_queue_time", kind: "float", original: "1e17", verdict: "equivalent",
       reason: "one more than 1e17 is the same float, so the change changes nothing"},
      {file: "log", method: "safe", kind: "condition_true", verdict: "equivalent",
       reason: "a logger without the method raises NoMethodError, and the rescue of the method answers nil as well"},
      {file: "plan/entry", method: "problem", kind: "condition_false", original: "defined?(@problem)", verdict: "equivalent",
       reason: "without the memo the verdict of the entry is worked out again from the same values, with the same result"},
      {file: "source/cpu/usage", method: "stat_ticks", kind: "integer", original: "1", verdict: "equivalent",
       reason: "the character after the closing parenthesis is a space, and split drops leading spaces"}
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
