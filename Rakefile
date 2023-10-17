# frozen_string_literal: true

require "bundler/gem_tasks"
require "standard/rake"

APPRAISAL_FILES = {
  "default" => %w[test_web.rb test_worker.rb test_configuration.rb test_resource.rb test_errors.rb],
  "rack" => %w[test_middleware.rb],
  "sidekiq" => %w[macro/test_sidekiq.rb],
  "bunny" => %w[macro/test_bunny.rb],
  "good_job" => %w[macro/test_good_job.rb],
  "delayed_job_active_record" => %w[macro/test_delayed_job.rb],
  "delayed_job_mongoid" => %w[macro/test_delayed_job.rb],
  "queue_classic" => %w[macro/test_queue_classic.rb],
  "resque" => %w[macro/test_resque.rb],
  "que" => %w[macro/test_que.rb]
}

APPRAISAL_VERSIONS = {
  "rack" => %w[2 3],
  "sidekiq" => %w[6 7],
  "bunny" => %w[2],
  "good_job" => %w[3], # revert to %w[2 3]
  "delayed_job_active_record" => %w[4],
  "delayed_job_mongoid" => %w[3],
  "queue_classic" => %w[4],
  "resque" => %w[2],
  "que" => %w[2]
}

def matrix
  APPRAISAL_FILES.each_with_object([]) do |(appraisal, _), matrix|
    (APPRAISAL_VERSIONS[appraisal] || [nil]).each do |version|
      matrix << [appraisal, version]
    end
  end
end

namespace :test do
  matrix.each do |appraisal, version|
    task_name = version ? "#{appraisal}-#{version}" : appraisal

    desc "Run tests for #{task_name}"
    task task_name do
      coverage = (ENV["COVERAGE"] == "false") ? "false" : "true"

      puts "\n\n=== Running tests for #{task_name} === \n\n"
      paths = APPRAISAL_FILES[appraisal].map { |file| File.expand_path("test/hirefire/#{file}") }
      command = "COVERAGE=#{coverage} appraisal #{task_name} ruby -Ilib:test -e '%w[#{paths.join(" ")}].each { |file| require file }'"
      puts "Current directory: #{Dir.pwd}"
      puts "Running: #{command}"
      success = system command
      exit(1) unless success
    end
  end
end

desc "Run tests for all libraries and versions using Appraisal"
task :test do
  ENV["COVERAGE"] = "false"

  matrix.each do |appraisal, version|
    task_name = version ? "#{appraisal}-#{version}" : appraisal
    Rake::Task["test:#{task_name}"].invoke
  end
end

task default: %i[test standard]
