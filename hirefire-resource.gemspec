Gem::Specification.new do |spec|
  spec.name = "hirefire-resource"
  spec.version = "0.10.0"
  spec.platform = Gem::Platform::RUBY
  spec.authors = "Michael van Rooijen"
  spec.email = "michael@hirefire.io"
  spec.homepage = "https://www.hirefire.io"
  spec.summary = "Autoscaling for your Heroku dynos"
  spec.description = "Load- and schedule-based scaling for web- and worker dynos"
  spec.licenses = ["Apache License"]
  spec.metadata = {
    "homepage_uri" => "https://www.hirefire.io",
    "changelog_uri" => "https://github.com/hirefire/hirefire-resource/blob/master/CHANGELOG.md",
    "source_code_uri" => "https://github.com/hirefire/hirefire-resource/",
    "bug_tracker_uri" => "https://github.com/hirefire/hirefire-resource/issues"
  }
  spec.files = `git ls-files`.split("\n")
  spec.require_path = "lib"
end
