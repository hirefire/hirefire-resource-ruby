require ::File.expand_path('../lib/hirefire-resource',  __FILE__)
require 'sidekiq'
use HireFire::Middleware
HireFire::Resource.configure do |config|
  config.dynos = :sidekiq
  config.dyno(:queue1){ rand(100) }
  config.dyno(:queue2){ rand(100) }
  config.dyno(:sidekiq) do
    HireFire::Macro::Sidekiq.queue(%w(low_facebook_metrics low_linkedin_metrics))
  end
  config.dyno(:facebook => /facebook/)
  config.dyno(:linkedin, /linkedin/)
  config.dyno(:social => [/facebook/, /linkedin/])
  config.dyno(:social_entities => [/facebook_entity/, /linkedin_entity/])

end

run lambda{|env| [200, {}, ["hello world"]] }
