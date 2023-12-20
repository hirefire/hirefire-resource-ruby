# frozen_string_literal: true

require "logger"

module HireFire
  class Configuration
    class LogQueueMetricsUnsupportedError < StandardError; end

    attr_reader :web, :workers
    attr_writer :log_queue_metrics
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

    def log_queue_metrics
      @log_queue_metrics ||= false
    end
  end
end
