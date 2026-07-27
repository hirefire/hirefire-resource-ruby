# frozen_string_literal: true

module HireFire
  module Identity
    module_function

    def resolve
      explicit || heroku_dyno || render_service
    end

    def explicit
      presence(ENV["HIREFIRE_SERVICE_NAME"])
    end

    def heroku_dyno
      dyno = presence(ENV["DYNO"])
      return unless dyno

      name = if dyno.include?(".")
        dyno.split(".").first
      else
        # Fir: process-X-Y (e.g. web-12a34b56d-e78f9). X/Y are platform-generated
        # alphanumerics; allow A-Z in case the suffix charset ever includes uppercase.
        dyno.sub(/-[A-Za-z0-9]+-[A-Za-z0-9]+\z/, "")
      end
      presence(name)
    end

    def render_service
      presence(ENV["RENDER_SERVICE_NAME"])
    end

    def heroku_conflict?
      explicit && heroku_dyno && !explicit.casecmp?(heroku_dyno)
    end

    # True when the platform marks this process as an HTTP web role (pre-traffic RQT arm).
    #
    # Universal RQT arming is traffic-first (middleware). This is an optional platform
    # improvement for idle heartbeats before the first request. Not a substitute for
    # identity or report names.
    #
    # @return [Boolean]
    def platform_http_role?
      heroku_web_process? || render_web_service?
    end

    # Heroku process type after Cedar/Fir strip equals +"web"+ (case-insensitive).
    # Exact match only: a naive +start_with?("web")+ would match +"worker"+.
    #
    # @return [Boolean]
    def heroku_web_process?
      name = heroku_dyno
      !name.nil? && name.casecmp?("web")
    end

    # Render service type is +"web"+ (public web service). Private services use +"pserv"+
    # and arm RQT via traffic (middleware) or explicit http registration.
    #
    # @return [Boolean]
    def render_web_service?
      type = presence(ENV["RENDER_SERVICE_TYPE"])
      !type.nil? && type.casecmp?("web")
    end

    # Strips leading/trailing whitespace (same class of paste footgun as the token).
    # Blank or whitespace-only values are treated as absent.
    #
    # @param value [String, nil]
    # @return [String, nil]
    def presence(value)
      return if value.nil?

      stripped = value.to_s.strip
      stripped unless stripped.empty?
    end
  end
end
