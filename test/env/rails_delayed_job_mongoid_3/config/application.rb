require_relative "boot"

require "action_controller/railtie"
require "action_mailer/railtie"

class RailsDelayedJob4Application < Rails::Application
  config.load_defaults 8.0
  config.root = File.expand_path("../..", __FILE__)
  config.eager_load = false
  config.active_job.queue_adapter = :delayed_job
end
