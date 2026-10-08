# frozen_string_literal: true

module Audit
  ROOT = File.expand_path("../..", __dir__)

  def self.results(*parts)
    File.join(ROOT, "audit/results", ENV.fetch("AUDIT_RUN", ""), *parts)
  end

  def self.coverage_file
    ENV["AUDIT_RUN"] ? results("coverage.json") : File.join(ROOT, "audit/baseline/coverage.json")
  end
end
