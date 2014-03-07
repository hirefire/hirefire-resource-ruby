# encoding: utf-8

module HireFire
  module Macro
    module Sidekiq
      extend self

      # Counts the amount of jobs in the (provided) Sidekiq queue(s).
      #
      # @example Sidekiq Macro Usage
      #   HireFire::Macro::Sidekiq.queue # all queues
      #   HireFire::Macro::Sidekiq.queue("email") # only email queue
      #   HireFire::Macro::Sidekiq.queue("audio", "video") # audio and video queues
      #
      # @param [Array] queues provide one or more queue names, or none for "all".
      # @return [Integer] the number of jobs in the queue(s).
      #
      def queue(*queues)
        queues = queues.flatten.map(&:to_s)
        queues = ::Sidekiq::Stats.new.queues.map { |name, _| name.to_s } if queues.empty?
        list = queue_list
        queues.inject(0) do |memo, name|
          memo += (list[name.to_s] || 0)
          memo
        end
      end


      def queue_list
        all_queues = Hash.new(0)
        queues = ::Sidekiq::Stats.new.queues.map { |name, _| name.to_s }
        queues.each do |name|
          all_queues[name] += ::Sidekiq::Queue.new(name).size
        end

        ::Sidekiq::ScheduledSet.new.each do |job|
          all_queues[job["queue"].to_s] += 1 if job.at <= Time.now
        end

        ::Sidekiq::RetrySet.new.each do |job|
          all_queues[job["queue"].to_s] += 1 if job.at <= Time.now
        end

        ::Sidekiq::Workers.new.each do |job|
          job_info = job[1]
          # As long as this is still a valid job
          if job_info && job_info["run_at"]
            all_queues[job_info["queue"].to_s] += 1 if job_info["run_at"] <= Time.now.to_i
          end
        end
        all_queues
      end

    end
  end
end

