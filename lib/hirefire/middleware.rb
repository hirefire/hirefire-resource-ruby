# frozen_string_literal: true

require "json"

module HireFire
  class Middleware
    def initialize(app)
      @app = app
      @path_prefix = determine_path_prefix
    end

    def call(env)
      process_request_queue_time(env)

      if matches_hirefire_path?(env) || matches_info_path?(env)
        return construct_info_response
      end

      @app.call(env)
    end

    private

    def matches_hirefire_path?(env)
      ENV["HIREFIRE_TOKEN"] && extract_path(env) == "/hirefire" && ENV["HIREFIRE_TOKEN"] == env["HTTP_HIREFIRE_TOKEN"]
    end

    def matches_info_path?(env)
      ENV["HIREFIRE_TOKEN"] && extract_path(env) == "/hirefire/#{ENV["HIREFIRE_TOKEN"]}/info"
    end

    def extract_path(env)
      @path_prefix ? env["PATH_INFO"].gsub(@path_prefix, "") : env["PATH_INFO"]
    end

    def construct_info_response
      [
        200,
        {
          "Content-Type" => "application/json",
          "Cache-Control" => "must-revalidate, private, max-age=0",
          "HireFire-Resource" => "Ruby-#{HireFire::VERSION}"
        },
        [
          HireFire.configuration.workers.map do |worker|
            {name: worker.name, value: worker.value}
          end.to_json
        ]
      ]
    end

    def process_request_queue_time(env)
      request_start = env["HTTP_X_REQUEST_START"]

      if HireFire.configuration.web && ENV["HIREFIRE_TOKEN"] && request_start
        request_queue_time = calculate_request_queue_time(request_start)
        collect_request_queue_time(request_queue_time)
      end

      if HireFire.configuration.log_queue_metrics && request_start
        request_queue_time = calculate_request_queue_time(request_start)
        log_request_queue_time(request_queue_time)
      end
    end

    def collect_request_queue_time(request_queue_time)
      HireFire
        .configuration
        .web
        .tap(&:start_dispatcher)
        .add_to_buffer(request_queue_time)
    end

    def log_request_queue_time(request_queue_time)
      puts "[hirefire:router] queue=#{request_queue_time}ms"
    end

    def calculate_request_queue_time(timestamp)
      [(Time.now.to_f * 1000).to_i - timestamp.to_i, 0].max
    end

    def determine_path_prefix
      if defined?(Rails) && Rails.application.config.relative_url_root
        Regexp.new("^" + Regexp.escape(Rails.application.config.relative_url_root))
      end
    end
  end
end
