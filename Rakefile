# frozen_string_literal: true

require "bundler/gem_tasks"
require "standard/rake"

APPRAISAL_FILES = {
  "default" => [
    "test_configuration.rb",
    "test_hirefire.rb",
    "test_version.rb",
    "test_web.rb",
    "test_worker.rb"
  ],
  "rack" => [
    "test_middleware.rb"
  ],
  "solid_queue" => [
    "macro/test_solid_queue.rb"
  ],
  "sidekiq" => [
    "macro/test_sidekiq.rb"
  ],
  "bunny" => [
    "macro/test_bunny.rb"
  ],
  "good_job" => [
    "macro/test_good_job.rb"
  ],
  "delayed_job_active_record" => [
    "macro/test_delayed_job.rb"
  ],
  "delayed_job_mongoid" => [
    "macro/test_delayed_job.rb"
  ],
  "queue_classic" => [
    "macro/test_queue_classic.rb"
  ],
  "resque" => [
    "macro/test_resque.rb"
  ],
  "que" => [
    "macro/test_que.rb"
  ]
}

APPRAISAL_VERSIONS = {
  "rack" => %w[2 3],
  "solid_queue" => %w[0],
  "sidekiq" => %w[6 7],
  "bunny" => %w[2],
  "good_job" => %w[2 3],
  "delayed_job_active_record" => %w[4],
  "delayed_job_mongoid" => %w[3],
  "queue_classic" => %w[4],
  "resque" => %w[2],
  "que" => %w[0 1 2]
}

def matrix
  APPRAISAL_FILES.each_with_object([]) do |(appraisal, _), matrix|
    (APPRAISAL_VERSIONS[appraisal] || [nil]).each do |version|
      matrix << [appraisal, version]
    end
  end
end

def construct_task_name(appraisal, version)
  version ? "#{appraisal}_#{version}" : appraisal
end

namespace :test do
  matrix.each do |appraisal, version|
    task_name = construct_task_name(appraisal, version)
    desc "Run tests for #{task_name}"
    task task_name do
      coverage = (ENV["COVERAGE"] == "false") ? "false" : "true"
      puts "\n\n# Running #{task_name} tests\n\n"
      paths = APPRAISAL_FILES[appraisal].map { |file| File.expand_path("test/hirefire/#{file}") }
      command = "COVERAGE=#{coverage} appraisal #{task_name} ruby -Ilib:test -e '%w[#{paths.join(" ")}].each { |file| require file }'"
      success = system command
      exit(1) unless success
    end
  end
end

desc "Run tests for all libraries and versions using Appraisal"
task :test do
  ENV["COVERAGE"] = "false"
  matrix.each do |appraisal, version|
    task_name = construct_task_name(appraisal, version)
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

task default: %i[test standard]

desc "Run checks: standard"
task check: ["standard"]

desc "Run formatters: standard:fix"
task format: ["standard:fix"]
