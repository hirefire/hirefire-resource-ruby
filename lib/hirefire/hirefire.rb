# frozen_string_literal: true

module HireFire
  extend self

  def configure
    yield configuration
    start_if_token
    configuration
  end

  def boot
    configure { |_| }
  end

  def configuration
    @configuration ||= Configuration.new
  end

  def reset
    @configuration&.stop_dispatcher
    @configuration = nil
  end

  def install_fork_hooks!
    return if defined?(@fork_hooks_installed) && @fork_hooks_installed
    return unless Process.respond_to?(:_fork)

    @fork_hooks_installed = true
    Process.singleton_class.prepend(ForkHook)
  end

  def after_fork_in_child
    if configuration.prefork_web_handoff?
      return unless configuration.token

      configuration.dispatcher.start
      configuration.dispatcher.ensure_job_queue_loop
    else
      configuration.dispatcher.abandon_inherited_state!
    end
  rescue => e
    Log.safe(configuration.logger, :error, "[HireFire] After-fork restart failed: #{e.message}")
  end

  def after_fork_in_parent
    return unless configuration.prefork_web_handoff?

    configuration.stop_dispatcher(flush: false)
  rescue => e
    Log.safe(configuration.logger, :error, "[HireFire] After-fork parent stop failed: #{e.message}")
  end

  module ForkHook
    def _fork
      pid = super
      if pid == 0
        HireFire.after_fork_in_child
      else
        HireFire.after_fork_in_parent
      end
      pid
    end
  end
  private_constant :ForkHook

  private

  def start_if_token
    return unless configuration.token

    configuration.dispatcher.start
    configuration.dispatcher.ensure_job_queue_loop
  end
end

HireFire.install_fork_hooks!

at_exit do
  HireFire.configuration.stop_dispatcher
rescue
  nil
end
