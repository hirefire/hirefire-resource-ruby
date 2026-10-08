# frozen_string_literal: true

module Audit
  module Mutation
    NIL_INITIALIZER = "the deleted line sets an instance variable to nil or false where the object is built, and an unset instance variable reads nil, which every reader treats the same"
    ONE_ROW = "the query returns one row, so the first row is the last"

    VERDICTS = [
      {method: "initialize", kind: "delete_statement", original: /\A@\w+ = (nil|false)\z/, verdict: "equivalent", reason: NIL_INITIALIZER},
      {file: "macro/que", kind: "method_swap", original: "first", verdict: "equivalent", reason: ONE_ROW},
      {file: "macro/helpers/good_job", method: "good_job_class", kind: "condition_true", verdict: "accepted",
       reason: "Good Job 3 answers every query of the macro the same through GoodJob::Job and GoodJob::Execution, so no test can tell them apart. The switch follows the Good Job upgrade guide"}
    ].freeze
  end
end
