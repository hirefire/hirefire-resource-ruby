# frozen_string_literal: true

module HireFire
  module Macro
    module Sidekiq
      # Process-local, sample-wave-scoped cache that amortizes Sidekiq schedule/retry due walks
      # across many macro calls in one Dispatcher#sample_job_queues run.
      #
      # Stores eligibility scores (+oldest_at+), per-queue due counts, and a rank cursor.
      # Latency ages are recomputed at read time against the live clock. Live lists and the
      # Lua (+server: true+) path never use this cache.
      #
      # Lifetime is one sample wave: +begin_sample!+ opens a clean epoch, +end_sample!+ clears
      # maps. Within a wave, free-hits reuse the registry. Outside a wave (console / one-off),
      # each +cache_for+ installs a fresh object so ad-hoc calls never share leftover state.
      # +now_fill+ is frozen at install for that set within the wave.
      #
      # @api private
      class DueCache
        BATCH = 1_000
        TRACE_LIMIT = 1_000
        FILL_WAIT_SECONDS = 1.0
        FILL_STUCK_SECONDS = 5.0

        attr_reader :set_name, :oldest_at, :size, :total_due, :complete,
          :cursor_rank, :now_fill, :global_oldest_at, :generation
        attr_writer :complete, :cursor_rank

        class << self
          attr_accessor :trace

          def clear_all
            mutex.synchronize do
              @sample_active = false
              @active_wave = nil
              @registry = {}
              @filling = {}
              @trace_log = []
              @generation_seq = {}
              condition.broadcast
            end
          end

          # Child-side fork reset: new mutex + empty registry. Must not lock the inherited
          # mutex (it may be stuck if the parent held it across fork).
          def reinit_after_fork!
            @mutex = Mutex.new
            @condition = ConditionVariable.new
            @sample_active = false
            @active_wave = nil
            @wave_seq = 0
            @registry = {}
            @filling = {}
            @trace_log = []
            @generation_seq = {}
          end

          # Open a sample-wave epoch (one Dispatcher#sample_job_queues run). Clears registry,
          # filling, and generation counters so every wave starts at rank 0.
          #
          # @return [Integer] monotonic wave token for +end_sample!+ ownership fencing
          def begin_sample!
            mutex.synchronize do
              @wave_seq = (@wave_seq || 0) + 1
              @active_wave = @wave_seq
              @sample_active = true
              @registry = {}
              @filling = {}
              @generation_seq = {}
              condition.broadcast
              @active_wave
            end
          end

          # Close the sample-wave epoch. Clears maps so the next wave cannot free-hit.
          #
          # When +wave+ is given (token from +begin_sample!+), no-ops unless that wave is still
          # active. An abandoned hung sample must not clear a later generation's maps.
          # When +wave+ is nil, force-clears the current wave (tests / explicit teardown).
          #
          # @param wave [Integer, nil]
          # @return [Boolean] true when maps were cleared
          def end_sample!(wave = nil)
            mutex.synchronize do
              if !wave.nil? && @active_wave != wave
                return false
              end

              @sample_active = false
              @active_wave = nil
              @registry = {}
              @filling = {}
              condition.broadcast
              true
            end
          end

          # Safe for external/test callers. Hot path under mutex must read +@sample_active+
          # directly (Ruby Mutex is not re-entrant).
          def sample_active?
            mutex.synchronize { @sample_active == true }
          end

          def zrange_start_ranks
            mutex.synchronize { (@trace_log || []).dup }
          end

          def clear_trace!
            mutex.synchronize { @trace_log = [] }
          end

          # @return [DueCache, nil]
          def peek(set_name)
            mutex.synchronize { registry[set_name.to_s] }
          end

          # Due latency contribution for one ZSET (schedule or retry), in seconds.
          #
          # @param set_name [String] +"schedule"+ or +"retry"+
          # @param queues [Set] empty means all queues
          # @return [Float]
          def latency(set_name, queues)
            needed = needed_from(queues)
            cache = ensure_walk(set_name, mode: :jql, needed: needed)
            return 0.0 unless cache

            score = if needed == :all
              cache.global_oldest_at
            else
              needed.filter_map { |q| cache.oldest_at[q] }.min
            end
            return 0.0 unless score

            Time.now.to_f - score
          end

          # Due size contribution for one ZSET.
          #
          # @param set_name [String] +"schedule"+ or +"retry"+
          # @param queues [Set] empty means all queues
          # @param max_scheduled [Integer, nil] schedule only: cap matching dues (policy A)
          # @return [Integer]
          def size(set_name, queues, max_scheduled: nil)
            set_name = set_name.to_s
            needed = needed_from(queues)
            cache = ensure_walk(set_name, mode: :jqs, needed: needed, max_scheduled: max_scheduled)
            return 0 unless cache

            count = matching_count(cache, needed)
            if set_name == "schedule" && !max_scheduled.nil?
              return 0 if max_scheduled <= 0

              return [count, max_scheduled].min
            end

            count
          end

          # Ensures the due walk is far enough for +mode+/+needed+, then returns the cache
          # object the caller must read (the filled draft or a satisfied registry entry).
          # Never re-peeks the registry after a fill: that avoids TOCTOU with concurrent install.
          #
          # @return [DueCache]
          def ensure_walk(set_name, mode:, needed:, max_scheduled: nil)
            set_name = set_name.to_s
            max_scheduled = nil unless set_name == "schedule" && mode == :jqs

            loop do
              cache = cache_for(set_name)
              return cache if walk_satisfied?(cache, mode, needed, max_scheduled)

              draft = nil
              fill_token = nil
              become_filler = false

              mutex.synchronize do
                cache = registry[set_name]
                cache = install_fresh(set_name) if cache.nil?
                return cache if walk_satisfied?(cache, mode, needed, max_scheduled)

                entry = filling[set_name]
                if entry && !fill_stuck?(entry)
                  condition.wait(mutex, FILL_WAIT_SECONDS)
                else
                  fill_token = Object.new
                  filling[set_name] = {
                    token: fill_token,
                    generation: cache.generation,
                    started_at: now_f
                  }
                  draft = cache.dup_for_fill
                  become_filler = true
                end
              end

              next unless become_filler

              begin
                walk!(draft, mode: mode, needed: needed, max_scheduled: max_scheduled)
                mutex.synchronize do
                  publish_draft!(set_name, draft, fill_token)
                end
                return draft
              ensure
                mutex.synchronize do
                  release_fill!(set_name, fill_token)
                end
              end
            end
          end

          def now_f
            Time.now.to_f
          end

          private

          def mutex
            @mutex ||= Mutex.new
          end

          def condition
            @condition ||= ConditionVariable.new
          end

          def registry
            @registry ||= {}
          end

          def filling
            @filling ||= {}
          end

          def generation_seq
            @generation_seq ||= {}
          end

          def needed_from(queues)
            (queues.nil? || queues.empty?) ? :all : queues
          end

          def matching_count(cache, needed)
            if needed == :all
              cache.total_due
            else
              needed.sum { |q| cache.size[q] }
            end
          end

          def jql_call_satisfied?(cache, needed)
            if needed == :all
              !cache.global_oldest_at.nil? || cache.complete
            else
              needed.any? { |q| cache.oldest_at.key?(q) } || cache.complete
            end
          end

          def walk_satisfied?(cache, mode, needed, max_scheduled)
            if mode == :jql
              jql_call_satisfied?(cache, needed)
            elsif max_scheduled.nil?
              cache.complete
            elsif cache.complete
              true
            else
              matching_count(cache, needed) >= max_scheduled
            end
          end

          def fill_stuck?(entry)
            now_f - entry[:started_at] >= FILL_STUCK_SECONDS
          end

          def cache_for(set_name)
            mutex.synchronize do
              unless @sample_active
                return install_fresh(set_name)
              end

              cache = registry[set_name]
              return cache if cache

              install_fresh(set_name)
            end
          end

          def install_fresh(set_name)
            generation_seq[set_name] = generation_seq.fetch(set_name, 0) + 1
            cache = new(
              set_name,
              now_f: now_f,
              generation: generation_seq[set_name]
            )
            registry[set_name] = cache
            cache
          end

          def publish_draft!(set_name, draft, fill_token)
            entry = filling[set_name]
            return unless entry && entry[:token].equal?(fill_token)

            current = registry[set_name]
            return unless current && current.generation == draft.generation

            registry[set_name] = draft
          end

          def release_fill!(set_name, fill_token)
            entry = filling[set_name]
            return unless entry && entry[:token].equal?(fill_token)

            filling.delete(set_name)
            condition.broadcast
          end

          def record_trace(set_name, start_rank)
            return unless trace

            mutex.synchronize do
              @trace_log ||= []
              @trace_log << {set_name: set_name.to_s, start_rank: start_rank}
              @trace_log.shift if @trace_log.size > TRACE_LIMIT
            end
          end

          def walk!(cache, mode:, needed:, max_scheduled:)
            matched_for_cap = matching_count(cache, needed)

            if mode == :jqs && !max_scheduled.nil? && matched_for_cap >= max_scheduled
              return :capped
            end

            loop do
              rank = cache.cursor_rank
              batch = zrange_batch(cache.set_name, rank)
              record_trace(cache.set_name, rank)

              if batch.empty?
                cache.complete = true
                return :ok
              end

              batch.each_with_index do |(member, score), i|
                score = score.to_f
                if score > cache.now_fill
                  cache.complete = true
                  cache.cursor_rank = rank + i + 1
                  return :ok
                end

                queue = parse_queue(member)
                if queue
                  cache.record_due(queue, score)
                  if !max_scheduled.nil? && (needed == :all || needed.include?(queue))
                    matched_for_cap += 1
                  end
                end

                cache.cursor_rank = rank + i + 1

                if mode == :jqs && !max_scheduled.nil? && matched_for_cap >= max_scheduled
                  return :capped
                end

                if mode == :jql && jql_call_satisfied?(cache, needed)
                  return :ok
                end
              end
            end
          end

          def zrange_batch(set_name, rank)
            ::Sidekiq.redis do |connection|
              if Gem::Version.new(::Sidekiq::VERSION) >= Gem::Version.new("7.0.0")
                connection.zrange(set_name, rank, rank + BATCH - 1, "WITHSCORES")
              else
                connection.zrange(set_name, rank, rank + BATCH - 1, withscores: true)
              end
            end
          end

          def parse_queue(member)
            payload = case member
            when String
              JSON.parse(member)
            when Hash
              member
            else
              return nil
            end
            return nil unless payload.is_a?(Hash)

            queue = payload["queue"]
            return nil if queue.nil? || queue == ""

            queue.to_s
          rescue JSON::ParserError, TypeError
            nil
          end
        end

        def initialize(set_name, now_f:, generation: 0)
          @set_name = set_name.to_s
          @now_fill = now_f
          @generation = generation
          @cursor_rank = 0
          @complete = false
          @oldest_at = {}
          @size = Hash.new(0)
          @total_due = 0
          @global_oldest_at = nil
        end

        def record_due(queue, score)
          @global_oldest_at ||= score
          @oldest_at[queue] ||= score
          @size[queue] += 1
          @total_due += 1
        end

        def dup_for_fill
          copy = self.class.allocate
          copy.instance_variable_set(:@set_name, @set_name)
          copy.instance_variable_set(:@now_fill, @now_fill)
          copy.instance_variable_set(:@generation, @generation)
          copy.instance_variable_set(:@cursor_rank, @cursor_rank)
          copy.instance_variable_set(:@complete, @complete)
          copy.instance_variable_set(:@oldest_at, @oldest_at.dup)
          size_copy = @size.dup
          size_copy.default = 0
          copy.instance_variable_set(:@size, size_copy)
          copy.instance_variable_set(:@total_due, @total_due)
          copy.instance_variable_set(:@global_oldest_at, @global_oldest_at)
          copy
        end
      end
    end
  end
end
