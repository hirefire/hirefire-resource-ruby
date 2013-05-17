# encoding: utf-8

Gem::Specification.new do |gem|
  gem.name        = "hirefire-resource"
  gem.version     = "0.1.1"
  gem.platform    = Gem::Platform::RUBY
  gem.authors     = "Michael van Rooijen"
  gem.email       = "michael@hirefire.io"
  gem.homepage    = "http://hirefire.io/"
  gem.summary     = "HireFire - The Heroku Dyno Manager"
  gem.description = "HireFire - The Heroku Dyno Manager"

  gem.files         = %x[git ls-files].split("\n")
  gem.executables   = ["hirefire", "hirefireapp"]
  gem.require_path  = "lib"
end

