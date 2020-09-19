# encoding: utf-8

Gem::Specification.new do |gem|
  gem.name = "hirefire-resource"
  gem.version = "0.8.1"
  gem.platform = Gem::Platform::RUBY
  gem.authors = "Michael van Rooijen"
  gem.email = "michael@hirefire.io"
  gem.homepage = "https://www.hirefire.io"
  gem.summary = "Autoscaling for your Heroku dynos"
  gem.description = "Load- and schedule-based scaling for web- and worker dynos"
  gem.licenses = ["Apache License"]
  gem.metadata = {
    "homepage_uri" => "https://www.hirefire.io",
    "changelog_uri" => "https://github.com/hirefire/hirefire-resource/blob/master/CHANGELOG.md",
    "source_code_uri" => "https://github.com/hirefire/hirefire-resource/",
    "bug_tracker_uri" => "https://github.com/hirefire/hirefire-resource/issues",
  }

  gem.files = %x[git ls-files].split("\n")
  gem.executables = ["hirefire", "hirefireapp"]
  gem.require_path = "lib"
end
