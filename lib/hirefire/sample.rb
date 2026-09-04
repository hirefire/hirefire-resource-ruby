# frozen_string_literal: true

module HireFire
  module Sample
    extend self

    def valid?(value)
      value.is_a?(Numeric) && value.finite? && value >= 0
    end

    def coerce(value)
      (value.is_a?(Integer) || value.is_a?(Float)) ? value : value.to_f
    end

    def format(value)
      text = value.class.name
      preview = value.to_s
      preview = "#{preview.byteslice(0, 64)}…" if preview.bytesize > 64
      "#{text}(#{preview.inspect})"
    rescue
      value.class.name
    end
  end
end
