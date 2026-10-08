# frozen_string_literal: true

module HireFire
  module Env
    def self.[](name)
      value = ENV[name].to_s.strip
      value unless value.empty?
    end
  end
end
