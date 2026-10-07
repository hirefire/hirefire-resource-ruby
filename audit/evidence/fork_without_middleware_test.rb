# frozen_string_literal: true

require "test_helper"

class ForkWithoutMiddlewareEvidence < Minitest::Test
  def test_a_web_process_keeps_dispatching_after_it_forks_a_helper
    ENV["HIREFIRE_TOKEN"] = "token"
    ENV["DYNO"] = "web.1"
    stub_request(:post, %r{data\.hirefire\.io/metrics/}).to_return(status: 200)
    HireFire.configure { |config| config.logger = Logger.new(File::NULL) }
    assert HireFire.configuration.dispatcher.running?

    pid = fork { exit!(0) }
    Process.wait(pid)
    sleep(1.5)

    assert HireFire.configuration.dispatcher.running?, "the dispatcher of the forking process stopped and nothing restarted it"
  end
end
