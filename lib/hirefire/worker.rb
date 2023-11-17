# frozen_string_literal: true

module HireFire
  class Worker
    class InvalidDynoName < StandardError; end

    class MissingDynoBlock < StandardError; end

    PROCESS_NAME_PATTERN = /\A[a-zA-Z][a-zA-Z0-9_]{0,29}\z/

    attr_reader :name

    def initialize(name, &block)
      unless name.to_s.match?(PROCESS_NAME_PATTERN)
        raise InvalidDynoName,
          "Invalid name for #{self.class}#dyno(#{name}, &block). " \
          "Ensure it matches the Procfile process name (i.e. web, worker)."
      end

      unless block
        raise MissingDynoBlock,
          "Missing block for #{self.class}#dyno(#{name}, &block). " \
          "Ensure that you provide a block of code that returns the queue metric."
      end

      @name = name
      @block = block
    end

    def call
      @block.call
    end
  end
end
