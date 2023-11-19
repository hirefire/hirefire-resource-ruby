# frozen_string_literal: true

require "logger"

module HireFire
  class Configuration
    class LogQueueMetricsUnsupportedError < StandardError; end

    attr_reader :web, :workers
    attr_accessor :logger

    def initialize
      @web = nil
      @workers = []
      @logger = Logger.new($stdout)
    end

    def dyno(name, &block)
      if name.to_s == "web"
        @web = Web.new
      else
        @workers << Worker.new(name, &block)
      end
    end

    def log_queue_metrics=(value)
      raise LogQueueMetricsUnsupportedError, <<~MSG
        `log_queue_metrics = true` has been replaced with `dyno(:web)`.

        Update your configuration file:

            HireFire.configure do |config|
          -   config.log_queue_metrics = true # <-- remove this line
          +   config.dyno(:web)               # <-- add this line
            end

        Please note that this change requires you to add the `HIREFIRE_TOKEN` environment variable
        to your Heroku application. You can find this token in the web dyno manager in the HireFire
        UI. If you are already autoscaling worker dynos, you are all set.

        With this change, metric data will no longer be logged to STDOUT. Instead, it will be sent
        directly to our servers from your web dynos.

        After deploying this change, you can also remove the Heroku logdrain:

          $ heroku drains:remove https://logdrain.hirefire.io -a <APP_NAME>

        Contact support for any questions or assistance.
      MSG
    end
  end
end
