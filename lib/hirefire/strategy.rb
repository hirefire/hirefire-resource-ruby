# frozen_string_literal: true

module HireFire
  module Strategy
    extend self

    RQT = "rqt"
    JQL = "jql"
    JQS = "jqs"
    CPU = "cpu"
    WRK = "wrk"
    JOB_QUEUE = [JQL, JQS].freeze

    def rqt?(strategy)
      strategy.to_s == RQT
    end

    def job_queue?(strategy)
      JOB_QUEUE.include?(strategy.to_s)
    end
  end
end
