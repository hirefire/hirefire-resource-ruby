# frozen_string_literal: true

module HireFire
  # Resolves this process's name (to match against a declared dyno name). First
  # non-empty source wins; nil means unresolved.
  module Identity
    module_function

    def resolve
      explicit || heroku_dyno || render_service
    end

    def explicit
      presence(ENV["HIREFIRE_SERVICE_NAME"])
    end

    # DYNO is "web.1" on Cedar, a pod name like "web-5fb9c979-lft2l" on Fir.
    # Strip the two trailing "-<alnum>" segments, keeping any dash inside the name.
    def heroku_dyno
      dyno = presence(ENV["DYNO"])
      return unless dyno

      if dyno.include?(".")
        dyno.split(".").first
      else
        dyno.sub(/-[a-z0-9]+-[a-z0-9]+\z/, "")
      end
    end

    def render_service
      presence(ENV["RENDER_SERVICE_NAME"])
    end

    # True when an explicit name disagrees with the DYNO prefix: a dashboard-set
    # (app-wide) HIREFIRE_SERVICE_NAME would make every dyno identify the same.
    def heroku_conflict?
      explicit && heroku_dyno && !explicit.casecmp?(heroku_dyno)
    end

    def presence(value)
      value if value && !value.empty?
    end
  end
end
