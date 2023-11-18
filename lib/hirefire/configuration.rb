# frozen_string_literal: true

require "logger"

module HireFire
  class Configuration
    attr_reader :web
    attr_reader :workers
    attr_accessor :logger

    def initialize
      @web = nil
      @workers = []
      @logger = Logger.new($stdout)
    end

    def log_queue_metrics
      @log_queue_metrics ||= false
    end

    attr_writer :log_queue_metrics

    def dyno(name, &block)
      if name.to_s == "web"
        @web = Web.new
      else
        @workers << Worker.new(name, &block)
      end
    end
  end
end
