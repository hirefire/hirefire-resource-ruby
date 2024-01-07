require_relative "lib/hirefire/version"

Gem::Specification.new do |spec|
  spec.name = "hirefire-resource"
  spec.version = HireFire::VERSION
  spec.platform = Gem::Platform::RUBY
  spec.authors = ["Michael van Rooijen"]
  spec.email = ["support@hirefire.io"]
  spec.homepage = "https://www.hirefire.io"
  spec.summary = "HireFire: Advanced Autoscalers for Heroku"
  spec.license = "MIT"
  spec.metadata["homepage_uri"] = "https://www.hirefire.io"
  spec.metadata["changelog_uri"] = "https://github.com/hirefire/hirefire-resource-ruby/blob/master/CHANGELOG.md"
  spec.metadata["source_code_uri"] = "https://github.com/hirefire/hirefire-resource-ruby/"
  spec.metadata["bug_tracker_uri"] = "https://github.com/hirefire/hirefire-resource-ruby/issues"
  spec.require_paths = ["lib"]
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) || f.start_with?(*%w[bin/ test/ .git .standard.yml Gemfile Rakefile])
    end
  end
  spec.required_ruby_version = ">= 2.7.0"
  spec.add_development_dependency "appraisal"
end
