# frozen_string_literal: true

require_relative "../../test/hirefire/macro/test_bunny"

class BunnyReusedConnectionEvidence < HireFire::Macro::BunnyTest
  def test_evidence_the_reused_connection_closes_when_sampling_stops
    setup_connection = ::Bunny.new(AMQP_URL).tap(&:start)
    setup_connection.create_channel.queue("audit-reuse", auto_delete: true)
    threads_before = Thread.list.size

    HireFire::Plan.around_job_queue_sample do
      HireFire::Macro::Bunny.job_queue_size("audit-reuse", **HireFire::Macro::Bunny.plan_connection_options)
    end
    connection = HireFire::Macro::Bunny.instance_variable_get(:@reused_connection)
    assert connection.open?
    HireFire.configuration.stop_dispatcher
    HireFire.reset

    refute connection.open?, "the connection is still open after the wave ended and the dispatcher stopped (threads: #{threads_before} before, #{Thread.list.size} now)"
  ensure
    connection&.close
    setup_connection&.close
  end
end
