# encoding: utf-8

Gem::Specification.new do |gem|
  gem.name = "hirefire-resource"
  gem.version = "0.3.3"
  gem.platform = Gem::Platform::RUBY
  gem.authors = "Michael van Rooijen"
  gem.email = "michael@hirefire.io"
  gem.homepage = "http://hirefire.io/"
  gem.summary = "Dyno management for Heroku"
  gem.description = "HireFire enables you to auto-scale your dynos, schedule capacity during specific times of the week, and recover crashed processes."
  gem.licenses = ["Apache License"]

  gem.files = %x[git ls-files].split("\n")
  gem.executables = ["hirefire", "hirefireapp"]
  gem.require_path = "lib"
end

