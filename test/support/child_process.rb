# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "timeout"
require "tmpdir"

module ChildProcess
  ROOT = File.expand_path("../..", __dir__)
  INHERITED = %w[BUNDLE_GEMFILE PATH HOME TMPDIR GEM_HOME GEM_PATH RUBYLIB RBENV_VERSION MISE_RUBY_VERSION COVERAGE COVERAGE_DIR].freeze

  def ruby_child(code, env = {})
    Dir.mktmpdir("hirefire-child") do |dir|
      result = File.join(dir, "result.json")
      script = File.join(dir, "script.rb")
      File.write(script, <<~RUBY)
        # frozen_string_literal: true
        require "bundler/setup"
        require "json"
        require #{File.join(ROOT, "test/support/coverage").inspect}
        $LOAD_PATH.unshift #{File.join(ROOT, "lib").inspect}
        value = begin
          #{code}
        end
        File.write(#{result.inspect}, JSON.generate([value]))
      RUBY

      cell = "#{ENV.fetch("COVERAGE_CELL", "tests")}-child-#{SecureRandom.hex(4)}"
      child_env = ENV.to_h.slice(*INHERITED).merge("COVERAGE_CELL" => cell).merge(env).compact
      stdout, stderr, status = Timeout.timeout(30) do
        Open3.capture3(child_env, RbConfig.ruby, script, unsetenv_others: true, chdir: ROOT)
      end

      assert status.success?, "the child process failed (#{status}):\n#{stdout}\n#{stderr}"
      JSON.parse(File.read(result)).first
    end
  end
end
