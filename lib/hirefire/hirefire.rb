# frozen_string_literal: true

# HireFire singleton entrypoint: configure processes and report metrics.
module HireFire
  extend self

  # Configures HireFire and starts reporting metrics when a token is present. Yields the
  # configuration object so each process can declare local sources (see
  # {HireFire::Configuration#dyno}). Zero-config installs can use {#boot} instead.
  #
  # After the block runs, the dispatcher starts automatically when a token is present, set in
  # code (`config.token = ...`) or via the `HIREFIRE_TOKEN` environment variable. With no token
  # the app runs normally and reports nothing, so it is safe to leave configured in every
  # environment.
  #
  # Configuration is additive: a later {#configure} may add local job-queue samplers without {#reset}.
  # Lease race entry and the job-queue loop are re-evaluated so late job-queue samplers take effect.
  #
  # @yieldparam config [HireFire::Configuration] the configuration to declare processes on.
  # @return [HireFire::Configuration] the configuration.
  # @example
  #   HireFire.configure do |config|
  #     config.dyno(:worker) { HireFire::Macro::Sidekiq.job_queue_latency(:default) }
  #   end
  def configure
    yield configuration
    start_if_token
    configuration
  end

  # Starts HireFire with no local source declarations.
  #
  # Equivalent to {#configure} with an empty block. Use for zero-config installs that rely on
  # always-on request queue time and CPU, plus lease plan macros for job-queue metrics. Full
  # {#configure} remains available for local job-queue samplers via {HireFire::Configuration#dyno}.
  #
  # @return [HireFire::Configuration] the configuration.
  # @example
  #   HireFire.boot
  def boot
    configure { |_| }
  end

  # The process-wide shared configuration.
  #
  # @return [HireFire::Configuration]
  def configuration
    @configuration ||= Configuration.new
  end

  # Stops any running dispatcher and replaces the configuration with a fresh, empty one. Mainly
  # for tests and reconfiguration between runs.
  #
  # @return [void]
  def reset
    @configuration&.stop_dispatcher
    @configuration = nil
  end

  # Installs a +Process._fork+ hook (Ruby 3.1+, required by this gem) so prefork clusters behave correctly:
  # the parent stops reporting (Puma/Unicorn master must not keep empty web liveness), and
  # each child restarts without needing middleware. Safe to call more than once.
  #
  # @return [void]
  def install_fork_hooks!
    return if defined?(@fork_hooks_installed) && @fork_hooks_installed
    return unless Process.respond_to?(:_fork)

    @fork_hooks_installed = true
    Process.singleton_class.prepend(ForkHook)
  end

  # Called in the child after +Process._fork+. Restarts reporting when a token is present.
  #
  # @return [void]
  def after_fork_in_child
    return unless configuration.token

    configuration.dispatcher.start
    configuration.dispatcher.ensure_job_queue_loop
  rescue => e
    Log.safe(configuration.logger, :error, "[HireFire] After-fork restart failed: #{e.message}")
  end

  # Called in the parent after +Process._fork+. Stops the dispatcher without a final flush so a
  # prefork master (Puma +preload_app!+, Unicorn) does not keep claiming empty web liveness under
  # the workers' process name. Children restart via {#after_fork_in_child} or middleware.
  # A later request in a parent that still serves traffic restarts via middleware {#start}.
  #
  # @return [void]
  def after_fork_in_parent
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
