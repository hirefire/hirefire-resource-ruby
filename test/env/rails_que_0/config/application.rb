require_relative "boot"

require "active_record/railtie"
require "que"

class RailsQue2Application < Rails::Application
  config.load_defaults 7.0
  config.root = File.expand_path("../..", __FILE__)
  config.active_record.schema_format = :sql
  config.eager_load = false
end
