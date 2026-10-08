# frozen_string_literal: true

if ENV["COVERAGE"] == "true"
  require "simplecov"

  SimpleCov.start do
    command_name ENV.fetch("COVERAGE_CELL", "tests")
    coverage_dir ENV.fetch("COVERAGE_DIR", "coverage")
    enable_coverage :branch
    merge_timeout 604_800
    track_files "lib/**/*.rb"
    add_filter { |source| !source.filename.start_with?(File.join(SimpleCov.root, "lib/")) }
    formatter SimpleCov::Formatter::SimpleFormatter if ENV["COVERAGE_DIR"]
  end
end
