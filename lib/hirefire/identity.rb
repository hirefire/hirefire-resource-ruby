# frozen_string_literal: true

module HireFire
  # Resolves the name of the process this code is running in, so collectors
  # can tell whether they should report under a given declared dyno name.
  # First non-empty source wins; nil means unresolved.
  module Identity
    module_function

    def resolve
      explicit || heroku_dyno || render_service
    end

    def explicit
      presence(ENV["HIREFIRE_SERVICE_NAME"])
    end

    # Heroku sets DYNO per generation: Cedar uses "web.1" (process type before
    # the first "."); Fir uses Kubernetes pod names like "web-5fb9c979-lft2l".
    # Stripping the two trailing "-<alnum>" segments, rather than splitting on
    # the first "-", keeps any dash inside a process name intact.
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

    # Heroku config vars are app-wide, so a dashboard-set HIREFIRE_SERVICE_NAME
    # makes every dyno identify as the same name. True when an explicit name
    # disagrees with the DYNO prefix. Case-insensitive, matching the identity
    # gates: names differing only in case gate identically.
    def heroku_conflict?
      explicit && heroku_dyno && !explicit.casecmp?(heroku_dyno)
    end

    def presence(value)
      value if value && !value.empty?
    end
  end
end
