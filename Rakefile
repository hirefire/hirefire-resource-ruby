# frozen_string_literal: true

require "bundler/gem_tasks"
require "standard/rake"

APPRAISAL_FILES = {
  "bunny" => [
    "macro/test_bunny.rb"
  ],
  "delayed_job_active_record" => [
    "macro/test_delayed_job.rb"
  ],
  "delayed_job_mongoid" => [
    "macro/test_delayed_job.rb"
  ],
  "good_job" => [
    "macro/test_good_job.rb"
  ],
  "que" => [
    "macro/test_que.rb"
  ],
  "queue_classic" => [
    "macro/test_queue_classic.rb"
  ],
  "rack" => [
    "test_middleware.rb"
  ],
  "resque" => [
    "macro/test_resque.rb"
  ],
  "sidekiq" => [
    "macro/test_sidekiq.rb"
  ],
  "solid_queue" => [
    "macro/test_solid_queue.rb"
  ]
}

# default is computed: every test file not claimed by a specific appraisal above.
claimed_files = APPRAISAL_FILES.values.flatten
APPRAISAL_FILES["default"] = Dir.glob("**/test_*.rb", base: File.expand_path("test/hirefire", __dir__))
  .reject { |file| claimed_files.include?(file) }
  .sort
APPRAISAL_FILES.freeze

APPRAISAL_VERSIONS = {
  "bunny" => %w[2 3],
  "delayed_job_active_record" => %w[4],
  "delayed_job_mongoid" => %w[3],
  "good_job" => %w[2 3 4],
  "que" => %w[0 1 2],
  "queue_classic" => %w[4],
  "rack" => %w[2 3],
  "resque" => %w[2 3],
  "sidekiq" => %w[6 7 8],
  "solid_queue" => %w[0 1]
}.freeze

def matrix
  APPRAISAL_FILES.keys.flat_map do |appraisal|
    (APPRAISAL_VERSIONS[appraisal] || [nil]).map { |version| [appraisal, version] }
  end
end

def task_name_for(appraisal, version)
  [appraisal, version].compact.join("_")
end

namespace :test do
  matrix.each do |appraisal, version|
    task_name = task_name_for(appraisal, version)
    desc "Run tests for #{task_name}"
    task task_name do
      coverage = (ENV["COVERAGE"] == "false") ? "false" : "true"
      puts "\n\n# Running #{task_name} tests\n\n"
      paths = APPRAISAL_FILES[appraisal].map { |file| File.expand_path("test/hirefire/#{file}") }
      command = "COVERAGE=#{coverage} appraisal #{task_name} ruby -Ilib:test -e '%w[#{paths.join(" ")}].each { |file| require file }'"
      exit(1) unless system(command)
    end
  end
end

desc "Run tests for all libraries and versions using Appraisal"
task :test do
  ENV["COVERAGE"] = "false"
  matrix.each do |appraisal, version|
    Rake::Task["test:#{task_name_for(appraisal, version)}"].invoke
  end
end

desc "Generate documentation"
task :doc do
  sh "yard"
end

namespace :doc do
  desc "Open documentation"
  task :open do
    sh "open doc/index.html"
  end

  desc "Run documentation server"
  task :server do
    sh "yard server --reload"
  end
end

desc "Run checks: standard"
task check: ["standard"]

desc "Run formatters: standard:fix"
task format: ["standard:fix"]

task default: %i[test standard]
