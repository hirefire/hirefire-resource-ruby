require ::File.expand_path('../lib/hirefire-resource',  __FILE__)
use HireFire::Middleware
HireFire::Resource.configure do |config|
  config.dyno(:queue1){ rand(100) }
  config.dyno(:queue2){ rand(100) }
end

run lambda{|env| [200, {}, ["hello world"]] }
