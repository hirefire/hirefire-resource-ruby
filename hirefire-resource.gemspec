require_relative "lib/hirefire/version"

Gem::Specification.new do |spec|
  spec.name = "hirefire-resource"
  spec.version = HireFire::VERSION
  spec.platform = Gem::Platform::RUBY
  spec.authors = ["Michael van Rooijen"]
  spec.email = ["support@hirefire.io"]
  spec.homepage = "https://hirefire.io"
  spec.summary = "HireFire integration library for Ruby applications"
  spec.license = "MIT"
  spec.metadata["homepage_uri"] = "https://hirefire.io"
  spec.metadata["documentation_uri"] = "https://www.rubydoc.info/gems/hirefire-resource"
  spec.metadata["changelog_uri"] = "https://github.com/hirefire/hirefire-resource-ruby/blob/master/CHANGELOG.md"
  spec.metadata["source_code_uri"] = "https://github.com/hirefire/hirefire-resource-ruby"
  spec.metadata["bug_tracker_uri"] = "https://github.com/hirefire/hirefire-resource-ruby/issues"
  spec.require_paths = ["lib"]
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").select do |f|
      f.start_with?(*%w[lib/ README.md LICENSE CHANGELOG.md hirefire-resource.gemspec])
    end
  end
  spec.required_ruby_version = ">= 2.7.0"
  spec.add_development_dependency "appraisal", "~> 2"
end
