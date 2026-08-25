# frozen_string_literal: true

require "bundler/gem_tasks"
require "standard/rake"

# Test files per appraisal *family*. Cell names and dependency pins live only in
# Appraisals (SSOT). CI uses `appraisal list`; local `rake test:*` parses the same file.
FAMILY_TEST_FILES = {
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
  "hanami" => [
    "integration/test_hanami.rb"
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
  "rails" => [
    "integration/test_rails.rb"
  ],
  "resque" => [
    "macro/test_resque.rb"
  ],
  "sidekiq" => [
    "macro/test_sidekiq.rb",
    "macro/test_sidekiq_due_cache.rb"
  ],
  "sinatra" => [
    "integration/test_sinatra.rb"
  ],
  "solid_queue" => [
    "macro/test_solid_queue.rb"
  ]
}.freeze

def appraisal_names
  File.read(File.expand_path("Appraisals", __dir__))
    .scan(/appraise\s+"([^"]+)"/)
    .flatten
end

def family_for(appraisal_name)
  return "default" if appraisal_name == "default"

  family = FAMILY_TEST_FILES.keys
    .select { |key| appraisal_name == key || appraisal_name.start_with?("#{key}_") }
    .max_by(&:length)
  raise "No test-file family for appraisal #{appraisal_name.inspect}" unless family

  family
end

def default_test_files
  claimed = FAMILY_TEST_FILES.values.flatten
  Dir.glob("**/test_*.rb", base: File.expand_path("test/hirefire", __dir__))
    .reject { |file| claimed.include?(file) }
    .sort
end

def test_files_for(appraisal_name)
  family = family_for(appraisal_name)
  return default_test_files if family == "default"

  FAMILY_TEST_FILES.fetch(family)
end

namespace :test do
  appraisal_names.each do |task_name|
    desc "Run tests for #{task_name}"
    task task_name do
      coverage = (ENV["COVERAGE"] == "false") ? "false" : "true"
      puts "\n\n# Running #{task_name} tests\n\n"
      paths = test_files_for(task_name).map { |file| File.expand_path("test/hirefire/#{file}") }
      command = "COVERAGE=#{coverage} appraisal #{task_name} ruby -Ilib:test -e '%w[#{paths.join(" ")}].each { |file| require file }'"
      exit(1) unless system(command)
    end
  end
end

desc "Run tests for all libraries and versions using Appraisal"
task :test do
  ENV["COVERAGE"] = "false"
  appraisal_names.each do |task_name|
    Rake::Task["test:#{task_name}"].invoke
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

desc "Fail if YARD emits warnings"
task "doc:check" do
  sh "bundle exec yard doc --fail-on-warning --no-progress"
end

desc "Run checks: standard and YARD"
task check: ["standard", "doc:check"]

desc "Run formatters: standard:fix"
task format: ["standard:fix"]

task default: %i[test standard]
