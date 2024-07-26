# frozen_string_literal: true

require_relative "deprecated/good_job"

module HireFire
  module Macro
    module GoodJob
      extend HireFire::Macro::Deprecated::GoodJob
      extend HireFire::Utility
      extend self

      # Calculates the maximum job queue latency using GoodJob. If no queues are specified, it
      # measures latency across all available queues.
      #
      # @param queues [Array<String, Symbol>] (optional) Names of the queues for latency
      #   measurement. If not provided, latency is measured across all queues.
      # @return [Float] Maximum job queue latency in seconds.
      # @example Calculate latency across all queues
      #   HireFire::Macro::GoodJob.job_queue_latency
      # @example Calculate latency for the "default" queue
      #   HireFire::Macro::GoodJob.job_queue_latency(:default)
      # @example Calculate latency across "default" and "mailer" queues
      #   HireFire::Macro::GoodJob.job_queue_latency(:default, :mailer)
      def job_queue_latency(*queues)
        queues = normalize_queues(queues, allow_empty: true)
        query = ::GoodJob::Execution
        query = query.where(queue_name: queues) if queues.any?
        query = query.where(performed_at: nil)
        query = query.where(scheduled_at: ..Time.now).or(query.where(scheduled_at: nil))
        query = query.order(scheduled_at: :asc, created_at: :asc)

        if (job = query.first)
          Time.now - (job.scheduled_at || job.created_at)
        else
          0.0
        end
      end

      # Calculates the total job queue size using GoodJob. If no queues are specified, it
      # measures size across all available queues.
      #
      # @param queues [Array<String, Symbol>] (optional) Names of the queues for size measurement.
      #   If not provided, size is measured across all queues.
      # @return [Integer] Total job queue size.
      # @example Calculate size across all queues
      #   HireFire::Macro::GoodJob.job_queue_size
      # @example Calculate size for the "default" queue
      #   HireFire::Macro::GoodJob.job_queue_size(:default)
      # @example Calculate size across "default" and "mailer" queues
      #   HireFire::Macro::GoodJob.job_queue_size(:default, :mailer)
      def job_queue_size(*queues)
        queues = normalize_queues(queues, allow_empty: true)
        query = ::GoodJob::Execution
        query = query.where(queue_name: queues) if queues.any?
        query = query.where(performed_at: nil)
        query = query.where(scheduled_at: ..Time.now).or(query.where(scheduled_at: nil))
        query.count
      end
    end
  end
end
