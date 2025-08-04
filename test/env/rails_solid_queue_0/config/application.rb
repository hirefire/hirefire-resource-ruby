require_relative "boot"

require "active_support/railtie"
require "active_job/railtie"
require "active_record/railtie"

require "solid_queue"

class RailsSolidQueue0Application < Rails::Application
  config.load_defaults 8.0
  config.root = File.expand_path("../..", __FILE__)
  config.eager_load = false
  config.active_job.queue_adapter = :solid_queue
end
