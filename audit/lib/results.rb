# frozen_string_literal: true

module Audit
  ROOT = File.expand_path("../..", __dir__)
  LOCAL = File.join(ROOT, "audit/results")
  RECORDED = ENV.fetch("AUDIT_RECORDED", LOCAL)

  def self.results(*parts)
    File.join(LOCAL, ENV.fetch("AUDIT_RUN", ""), *parts)
  end

  def self.recorded(*parts)
    File.join(RECORDED, *parts)
  end

  def self.coverage_file
    results("coverage.json")
  end
end
