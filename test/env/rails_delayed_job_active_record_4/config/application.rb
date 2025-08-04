require "active_job/railtie"
require "active_record/railtie"
require "delayed_job"

class RailsDelayedJob4Application < Rails::Application
  config.load_defaults 8.0
  config.root = File.expand_path("../..", __FILE__)
  config.eager_load = false
  config.active_job.queue_adapter = :delayed_job
end
