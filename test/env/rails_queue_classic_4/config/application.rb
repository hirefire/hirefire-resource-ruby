require_relative "boot"

require "active_record/railtie"

class RailsQC4Application < Rails::Application
  config.load_defaults 7.0
  config.root = File.expand_path("../..", __FILE__)
  config.eager_load = false
  config.active_record.schema_format = :sql
end
