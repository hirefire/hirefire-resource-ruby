# frozen_string_literal: true

module HireFire
  class Worker
    class InvalidDynoNameError < StandardError; end

    class MissingDynoBlockError < StandardError; end

    PROCESS_NAME_PATTERN = /\A[a-zA-Z][a-zA-Z0-9_-]{0,29}\z/

    attr_reader :name

    def initialize(name, &block)
      validate(name, &block)
      @name = name
      @block = block
    end

    def value
      @block.call
    end

    private

    def validate(name, &block)
      unless name.to_s.match?(PROCESS_NAME_PATTERN)
        raise InvalidDynoNameError,
          "Invalid name for HireFire::Worker.new(#{name}, &block). " \
          "Ensure it matches the Procfile process name (i.e. web, worker)."
      end

      unless block
        raise MissingDynoBlockError,
          "Missing block for HireFire::Worker.new(#{name}, &block). " \
          "Ensure that you provide a block that returns the job queue metric."
      end
    end
  end
end
