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
    Plan.release_macros(configuration.logger)
    HANDOFF_LOCK.synchronize { @handoffs = nil }
    @configuration = nil
  end

  def install_fork_hooks!
    return if defined?(@fork_hooks_installed) && @fork_hooks_installed
    return unless Process.respond_to?(:_fork)

    @fork_hooks_installed = true
    Process.singleton_class.prepend(ForkHook)
  end

  def after_fork_in_child
    @handoffs = @handoff_watch = nil
    if configuration.prefork_web_handoff?
      return unless configuration.token

      configuration.dispatcher.start
    else
      configuration.dispatcher.abandon_inherited_state!
    end
  rescue => e
    Log.safe(configuration.logger, :error, "[HireFire] After-fork restart failed: #{e.message}")
  end

  def after_fork_in_parent(child)
    return unless configuration.prefork_web_handoff?

    HANDOFF_LOCK.synchronize do
      configuration.stop_dispatcher(flush: false)
      (@handoffs ||= []) << child
      @handoff_watch ||= watch_handoffs
    end
  rescue => e
    Log.safe(configuration.logger, :error, "[HireFire] After-fork parent stop failed: #{e.message}")
  end

  def after_daemon(restart)
    @handoffs = @handoff_watch = nil
    configuration.dispatcher.start if restart
  rescue => e
    Log.safe(configuration.logger, :error, "[HireFire] After-daemon restart failed: #{e.message}")
  end

  module ForkHook
    def _fork
      pid = super
      if pid == 0
        HireFire.after_fork_in_child
      else
        HireFire.after_fork_in_parent(pid)
      end
      pid
    end

    def daemon(*)
      running = HireFire.configuration.dispatcher.running?
      super.tap { HireFire.after_daemon(running) }
    end
  end
  private_constant :ForkHook

  HANDOFF_LOCK = Mutex.new
  private_constant :HANDOFF_LOCK

  private

  def watch_handoffs
    thread = Thread.new do
      sleep(Dispatcher::TICK) until handoffs_settled?
    rescue => e
      HANDOFF_LOCK.synchronize { @handoffs = @handoff_watch = nil }
      Log.safe(configuration.logger, :error, "[HireFire] After-fork resume failed: #{e.message}")
    end
    thread.name = "hirefire-handoff"
    thread
  end

  def handoffs_settled?
    HANDOFF_LOCK.synchronize do
      if @handoffs && !configuration.dispatcher.running?
        return false if @handoffs.keep_if { |child| process_alive?(child) }.any?

        start_if_token
      end
      @handoffs = @handoff_watch = nil
      true
    end
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def start_if_token
    return unless configuration.token
    return if Identity.one_off?

    configuration.dispatcher.start
  end
end

HireFire.install_fork_hooks!

at_exit do
  HireFire.instance_variable_get(:@configuration)&.stop_dispatcher
rescue
  nil
end
