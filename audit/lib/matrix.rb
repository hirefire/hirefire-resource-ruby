# frozen_string_literal: true

require "rake"

module Audit
  module Matrix
    extend self

    ROOT = File.expand_path("../..", __dir__)

    def cells
      @cells ||= begin
        Dir.chdir(ROOT) { load File.join(ROOT, "Rakefile") }
        appraisal_names.to_h { |name| [name, test_files_for(name)] }
      end
    end

    def test_paths(cell)
      cells.fetch(cell).map { |file| File.join(ROOT, "test/hirefire", file) }
    end

    def gemfile(cell)
      File.join(ROOT, "gemfiles", "#{cell}.gemfile")
    end
  end
end
