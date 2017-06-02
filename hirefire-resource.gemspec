# encoding: utf-8

Gem::Specification.new do |gem|
  gem.name = "hirefire-resource"
  gem.version = "0.4.2"
  gem.platform = Gem::Platform::RUBY
  gem.authors = "Michael van Rooijen"
  gem.email = "michael@hirefire.io"
  gem.homepage = "https://www.hirefire.io"
  gem.summary = "Autoscaling for your Heroku dynos"
  gem.description = "Load- and schedule-based scaling for web- and worker dynos"
  gem.licenses = ["Apache License"]

  gem.files = %x[git ls-files].split("\n")
  gem.executables = ["hirefire", "hirefireapp"]
  gem.require_path = "lib"
end
