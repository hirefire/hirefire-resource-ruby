# frozen_string_literal: true

module HireFire
  module Identity
    extend self

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

    def platform_http_role?
      heroku_web_process? || render_web_service?
    end

    def heroku_web_process?
      name = heroku_dyno
      !name.nil? && name.casecmp?("web")
    end

    def render_web_service?
      type = presence(ENV["RENDER_SERVICE_TYPE"])
      !type.nil? && type.casecmp?("web")
    end

    def presence(value)
      return if value.nil?

      stripped = value.to_s.strip
      stripped unless stripped.empty?
    end
  end
end
