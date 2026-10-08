# frozen_string_literal: true

module Tools
  ROOT = File.expand_path("../..", __dir__)

  def self.results(*parts)
    File.join(ROOT, "tools/results", ENV.fetch("TOOLS_RUN", ""), *parts)
  end

  def self.coverage_file
    results("coverage.json")
  end
end
