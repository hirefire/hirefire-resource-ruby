# frozen_string_literal: true

require "simplecov"

SimpleCov.start do
  command_name ENV.fetch("AUDIT_CELL")
  coverage_dir ENV.fetch("AUDIT_COVERAGE_DIR")
  enable_coverage :branch
  primary_coverage :line
  merge_timeout 604_800
  track_files "lib/**/*.rb"
  add_filter { |source| !source.filename.start_with?(File.join(SimpleCov.root, "lib/")) }
  formatter SimpleCov::Formatter::SimpleFormatter
end
