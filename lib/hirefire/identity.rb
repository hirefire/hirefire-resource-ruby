# frozen_string_literal: true

module HireFire
  # Resolves the name of the process this code is running in, so the CPU
  # collector can tell whether it should report under a given declared name
  # (a worker dyno must not report CPU under "web"). Resolution order, first
  # non-empty wins:
  #
  #   HIREFIRE_SERVICE_NAME  ||  DYNO prefix (Heroku)  ||  RENDER_SERVICE_NAME (Render)  ||  nil
  #
  # An explicit HIREFIRE_SERVICE_NAME wins so a wrong auto-detection can be
  # overridden. Returns nil ("unresolved") when nothing identifies the process.
  module Identity
    module_function

    def resolve
      explicit || heroku_dyno || render_service
    end

    # HIREFIRE_SERVICE_NAME, set explicitly by the user. The portable override
    # for any platform (Docker/K8s/DigitalOcean) and the escape hatch elsewhere.
    def explicit
      presence(ENV["HIREFIRE_SERVICE_NAME"])
    end

    # Heroku sets DYNO per generation: Cedar uses "web.1" / "worker.2" (process
    # type before the first "."); Fir uses Kubernetes pod names like
    # "web-5fb9c979-lft2l" (process type plus two generated suffix segments).
    # Stripping the two trailing "-<alnum>" segments, rather than splitting on
    # the first "-", keeps any dash inside a process name intact. Zero-config
    # on both generations.
    def heroku_dyno
      dyno = presence(ENV["DYNO"])
      return unless dyno

      if dyno.include?(".")
        dyno.split(".").first
      else
        dyno.sub(/-[a-z0-9]+-[a-z0-9]+\z/, "")
      end
    end

    # Render exposes the service name directly. Zero-config when the Render
    # service name equals the declared dyno name.
    def render_service
      presence(ENV["RENDER_SERVICE_NAME"])
    end

    # Heroku config vars are app-wide, so a dashboard-set HIREFIRE_SERVICE_NAME
    # makes every dyno identify as the same name. True when an explicit name is
    # present alongside a DYNO whose prefix disagrees — the footgun to warn about.
    def heroku_conflict?
      explicit && heroku_dyno && explicit != heroku_dyno
    end

    def presence(value)
      value if value && !value.empty?
    end
  end
end
