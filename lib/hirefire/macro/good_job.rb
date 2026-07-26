# frozen_string_literal: true

require_relative "helpers/active_record_connection"
require_relative "../plan/hooks"
require_relative "helpers/good_job"
require_relative "deprecated/good_job"

module HireFire
  module Macro
    module GoodJob
      extend HireFire::Utility
      extend HireFire::Macro::Helpers::ActiveRecordConnection
      extend HireFire::Plan::Hooks
      extend HireFire::Macro::Helpers::GoodJob
      extend HireFire::Macro::Deprecated::GoodJob
      extend self

      # Calculates the maximum job queue latency using GoodJob. If no queues are specified, it
      # measures latency across all available queues.
      #
      # Counts only ready (queued) jobs: +finished_at+ and +performed_at+ both null, due to run
      # (+scheduled_at+ in the past or null). Terminal rows (including discard-before-run) and
      # currently running jobs are excluded.
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
        with_connection do
          query = ready_jobs(*queues).order(Arel.sql("COALESCE(scheduled_at, created_at) ASC"))

          if (job = query.first)
            Time.now - (job.scheduled_at || job.created_at)
          else
            0.0
          end
        end
      end

      # Calculates the total job queue size using GoodJob. If no queues are specified, it
      # measures size across all available queues.
      #
      # Counts only ready (queued) jobs: +finished_at+ and +performed_at+ both null, due to run
      # (+scheduled_at+ in the past or null). Terminal rows (including discard-before-run) and
      # currently running jobs are excluded.
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
        with_connection do
          ready_jobs(*queues).count
        end
      end

      private

      # Ready queue relation aligned with GoodJob's +queued+ notion (unfinished and not started),
      # plus null +scheduled_at+ as due, and discard +error_event+ as defense in depth.
      def ready_jobs(*queues)
        queues = normalize_queues(queues, allow_empty: true)
        query = good_job_class
        query = query.where(queue_name: queues) if queues.any?
        query = query.where(finished_at: nil, performed_at: nil)
        query = query.where.not(error_event: discarded_enum).or(query.where(error_event: nil)) if error_event_supported?
        query.where("scheduled_at <= ?", Time.now).or(query.where(scheduled_at: nil))
      end
    end
  end
end
