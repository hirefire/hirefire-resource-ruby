require_relative "boot"

require "active_job/railtie"
require "active_record/railtie"
require "good_job"

class RailsGoodJob3Application < Rails::Application
  config.load_defaults 7.0
  config.root = File.expand_path("../..", __FILE__)
  config.eager_load = false
  config.active_job.queue_adapter = :good_job
  config.good_job.execution_mode = :external
end
