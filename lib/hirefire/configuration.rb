# frozen_string_literal: true

require "logger"

module HireFire
  class Configuration
    attr_reader :web, :workers, :log_queue_metrics
    attr_writer :token, :log_queue_metrics
    attr_accessor :logger

    def initialize
      @web = nil
      @workers = Workers.new
      @dispatcher = nil
      @logger = Logger.new($stdout)
      @token = nil
      @log_queue_metrics = false
    end

    def token
      @token || ENV["HIREFIRE_TOKEN"]
    end

    def process(name, &sampler)
      if sampler
        @workers << Worker.new(name, &sampler)
      else
        @web = Web.new(name: name)
      end
    end

    class MissingSamplerError < StandardError; end

    def dyno(name, &sampler)
      if name.to_s == "web"
        @web = Web.new(name: name)
      else
        raise MissingSamplerError, "Missing sampler for config.dyno(:#{name}) { ... }" unless sampler
        @workers << Worker.new(name, &sampler)
      end
    end

    def buffer
      @buffer ||= Buffer.new
    end

    def dispatcher
      @dispatcher ||= Dispatcher.new(web: @web, workers: @workers)
    end
  end
end
