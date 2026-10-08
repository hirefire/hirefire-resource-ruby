# frozen_string_literal: true

module HireFire
  module Macro
    module Sidekiq
      class DueCache
        BATCH = 1_000
        WALK_MEMBER_BUDGET = 50_000
        WALK_TIME_BUDGET = 2.0
        WORKING_MEMBER_BUDGET = 20_000

        @mutex = Mutex.new
        @rounds = 0
        @round = nil
        @caches = {}
        @working = nil

        class << self
          def reinit_after_fork
            @mutex = Mutex.new
            @round = nil
            @caches = {}
            @working = nil
          end

          def begin_sample!
            @mutex.synchronize do
              @caches = {}
              @working = nil
              @round = (@rounds += 1)
            end
          end

          def end_sample!(round = nil)
            @mutex.synchronize do
              next if round && round != @round

              @round = nil
              @caches = {}
              @working = nil
            end
          end

          def working_jobs
            @mutex.synchronize do
              next read_working_jobs unless @round

              @working ||= read_working_jobs
            end
          end

          def latency(set_name, queues)
            return first_due_age(set_name) if queues.empty?

            walk(set_name) { |cache| cache.latency(queues) }
          end

          def size(set_name, queues, max_scheduled: nil)
            return due_count(set_name, Time.now.to_f) if queues.empty?

            cap = [max_scheduled, 0].max if max_scheduled
            walk(set_name) { |cache| cache.size(queues, cap) }
          end

          def due_count(set_name, now)
            ::Sidekiq.redis { |connection| connection.zcount(set_name, "-inf", now) }.to_i
          end

          private

          def walk(set_name)
            @mutex.synchronize do
              yield(@round ? (@caches[set_name] ||= new(set_name)) : new(set_name))
            end
          end

          def first_due_age(set_name)
            _member, score = ::Sidekiq.redis { |connection| connection.zrange(set_name, 0, 0, "WITHSCORES") }.first
            now = Time.now.to_f
            (score && score.to_f <= now) ? now - score.to_f : 0.0
          end

          def read_working_jobs
            started = Clock.monotonic
            jobs = []
            ::Sidekiq::Workers.new.each do |_key, _tid, job|
              jobs << job
              if jobs.size >= WORKING_MEMBER_BUDGET || (Clock.monotonic - started) >= WALK_TIME_BUDGET
                raise HireFire::Errors::SampleIncompleteError, "Sidekiq working map exceeded budget"
              end
            end
            jobs
          end
        end

        def initialize(set_name)
          @set_name = set_name
          @now = Time.now.to_f
          @cursor = 0
          @complete = false
          @unwalked = nil
          @unwalked_from = nil
          @oldest = {}
          @sizes = Hash.new(0)
        end

        def latency(queues)
          walk { queues.any? { |queue| @oldest.key?(queue) } }
          score = queues.filter_map { |queue| @oldest[queue] }.min || @unwalked_from
          score ? Time.now.to_f - score : 0.0
        end

        def size(queues, cap)
          walk { cap && matched(queues) >= cap }
          count = matched(queues) + @unwalked.to_i
          cap ? [count, cap].min : count
        end

        private

        def matched(queues)
          queues.sum { |queue| @sizes[queue] }
        end

        def walk
          seen = 0
          started = Clock.monotonic

          until @complete || @unwalked || yield
            batch = ::Sidekiq.redis { |connection| connection.zrange(@set_name, @cursor, @cursor + BATCH - 1, "WITHSCORES") }
            @complete = true if batch.empty?

            batch.each do |member, score|
              score = score.to_f
              break @complete = true if score > @now

              seen += 1
              break stop_over_budget(score) if seen >= WALK_MEMBER_BUDGET || (Clock.monotonic - started) >= WALK_TIME_BUDGET

              record(member, score)
              @cursor += 1
              break if yield
            end
          end
        end

        def stop_over_budget(score)
          @unwalked = [self.class.due_count(@set_name, @now) - @cursor, 0].max
          @unwalked_from = score
        end

        def record(member, score)
          queue = queue_of(member)
          @oldest[queue] ||= score
          @sizes[queue] += 1
        end

        def queue_of(member)
          payload = JSON.parse(member)
          payload["queue"].to_s if payload.is_a?(Hash)
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
