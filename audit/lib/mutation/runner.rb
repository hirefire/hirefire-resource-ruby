# frozen_string_literal: true

require "bundler"
require "fileutils"
require "json"
require_relative "generator"

module Audit
  module Mutation
    class Runner
      FREE_CELLS = %w[default rack_2 rack_3 rails_7 rails_8 sinatra_3 sinatra_4 hanami_2 hanami_3].freeze
      CELL_TIMEOUT = 45
      FOCUSED = {
        "dispatcher/session" => %w[test_dispatcher.rb test_wire.rb],
        "dispatcher/failure_log" => %w[test_dispatcher.rb],
        "plan/entry" => %w[plan/test_entry.rb test_sampler.rb],
        "sample" => %w[test_sampler.rb],
        "source/cpu/usage" => %w[test_cpu.rb test_cpu_platform.rb],
        "source/cpu" => %w[test_cpu.rb],
        "source/http" => %w[test_source_http.rb],
        "source/job_queue" => %w[test_source_job_queue.rb],
        "source/job_queues" => %w[test_source_job_queues.rb],
        "version" => %w[test_hirefire.rb]
      }.freeze

      def initialize(root:, results:, free_dirs:, service_dirs:, cells:, coverage:, files:)
        @root = root
        @results = results
        @free_dirs = free_dirs
        @service_dirs = service_dirs
        @cells = cells
        @line_cells = coverage.fetch("line_cells")
        @relevant_lines = coverage.fetch("relevant_lines")
        @files = files
        @write = Mutex.new
        @free_queue = Queue.new
        @service_queue = Queue.new
        @pending = 0
        @pending_lock = Mutex.new
        @done = ConditionVariable.new
      end

      def run
        known = File.exist?(@results) ? File.readlines(@results).map { |line| JSON.parse(line).fetch("id") } : []
        mutants = @files.flat_map { |file| Generator.call(@root, file) }.reject { |mutant| known.include?(mutant.id) }
        puts "#{mutants.size} mutants to run (#{known.size} already recorded)"

        preflight

        mutants.each do |mutant|
          covering = covering_cells(mutant)
          if covering.empty?
            write(mutant, status: "uncovered", cells_run: [], covering: [])
            next
          end

          free = covering & FREE_CELLS
          job = {mutant: mutant, covering: covering, free: free, service: covering - free, run: []}
          @pending_lock.synchronize { @pending += 1 }
          (free.empty? ? @service_queue : @free_queue) << job
        end

        workers = @free_dirs.map { |dir| Thread.new { work(@free_queue, dir, :free) } }
        workers += @service_dirs.map { |dir| Thread.new { work(@service_queue, dir, :service) } }
        @pending_lock.synchronize { @done.wait(@pending_lock) until @pending.zero? }
        (@free_dirs.size + @service_dirs.size).times { |index| ((index < @free_dirs.size) ? @free_queue : @service_queue) << :stop }
        workers.each(&:join)
      end

      private

      def preflight
        (@free_dirs + @service_dirs).each { |dir| FileUtils.cp_r(File.join(@root, "lib/."), File.join(dir, "lib")) }
        checks = @free_dirs.map { |dir| [dir, FREE_CELLS] } + @service_dirs.map { |dir| [dir, @cells.keys - FREE_CELLS] }
        failures = checks.map do |dir, cells|
          Thread.new { cells.reject { |cell| run_cell(dir, cell) == :passed }.map { |cell| "#{dir}: #{cell}" } }
        end.flat_map(&:value)
        abort "unmutated cells fail, so no result would mean anything:\n#{failures.join("\n")}" if failures.any?

        puts "preflight passed in #{checks.size} worker directories"
      end

      def covering_cells(mutant)
        lines = @line_cells[mutant.file] || {}
        relevant = @relevant_lines[mutant.file] || []
        span = (mutant.line..(mutant.line + mutant.original.count("\n"))).to_a
        if (span & relevant).empty?
          anchor = relevant.select { |line| line < mutant.line }.max
          span = [anchor] if anchor
        end
        cells = span.flat_map { |line| lines[line.to_s] || [] }.uniq
        cells = lines.values.flatten.uniq if cells.empty?
        cells.empty? ? ["default"] : cells
      end

      def work(queue, dir, pool)
        loop do
          job = queue.pop
          break if job == :stop

          mutant = job.fetch(:mutant)
          path = File.join(dir, mutant.file)
          original = File.read(File.join(@root, mutant.file))
          killer = nil
          timed_out = false
          begin
            File.write(path, mutant.apply(original))
            stages = job.fetch(pool).map { |cell| [cell, cell, nil] }
            focused = (pool == :free) ? focused_tests(dir, mutant.file) : []
            stages.unshift(["focused", "default", focused]) if focused.any?
            stages.each do |label, cell, paths|
              outcome = run_cell(dir, cell, paths)
              job[:run] << label
              next if outcome == :passed

              killer = label
              timed_out = outcome == :timeout
              break
            end
          ensure
            File.write(path, original)
          end

          if killer
            finish(job, status: timed_out ? "timeout" : "killed", killed_by: killer)
          elsif pool == :free && job.fetch(:service).any?
            @service_queue << job
          else
            finish(job, status: "survived")
          end
        end
      end

      def finish(job, **fields)
        write(job.fetch(:mutant), cells_run: job.fetch(:run), covering: job.fetch(:covering), **fields)
        @pending_lock.synchronize do
          @pending -= 1
          @done.broadcast if @pending.zero?
        end
      end

      def focused_tests(dir, file)
        name = file.delete_prefix("lib/hirefire/").delete_suffix(".rb")
        tests = FOCUSED[name] || [File.join(File.dirname(name), "test_#{File.basename(name)}.rb").delete_prefix("./")]
        (tests & @cells.fetch("default")).map { |test| File.join(dir, "test/hirefire", test) }
      end

      def run_cell(dir, cell, paths = nil)
        paths ||= @cells.fetch(cell).map { |file| File.join(dir, "test/hirefire", file) }
        env = {"BUNDLE_GEMFILE" => File.join(dir, "gemfiles/#{cell}.gemfile"), "COVERAGE" => "false"}
        command = ["bundle", "exec", "ruby", "-Ilib:test", "-e", "ARGV.each { |file| require file }", *paths]
        Bundler.with_unbundled_env do
          pid = Process.spawn(env, *command, chdir: dir, out: File::NULL, err: File::NULL, pgroup: true)
          waiter = Thread.new { Process.wait2(pid).last }
          if waiter.join(CELL_TIMEOUT)
            waiter.value.success? ? :passed : :failed
          else
            begin
              Process.kill("KILL", -pid)
            rescue Errno::ESRCH
              nil
            end
            waiter.join
            :timeout
          end
        end
      end

      def write(mutant, **fields)
        record = {
          id: mutant.id, file: mutant.file, line: mutant.line, kind: mutant.kind,
          original: mutant.original, replacement: mutant.replacement
        }.merge(fields)
        @write.synchronize { File.write(@results, JSON.generate(record) + "\n", mode: "a") }
      end
    end
  end
end
