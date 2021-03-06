module ScoutApm
  # The entry-point for the ScoutApm Agent.
  #
  # Only one Agent instance is created per-Ruby process, and it coordinates the lifecycle of the monitoring.
  #   - initializes various data stores
  #   - coordinates configuration & logging
  #   - starts background threads, running periodically
  #   - installs shutdown hooks
  class Agent
    # see self.instance
    @@instance = nil

    attr_reader :context

    attr_accessor :options # options passed to the agent when +#start+ is called.

    attr_reader :instrument_manager

    # All access to the agent is thru this class method to ensure multiple Agent instances are not initialized per-Ruby process.
    def self.instance(options = {})
      @@instance ||= self.new(options)
    end

    # First call of the agent. Does very little so that the object can be created, and exist.
    def initialize(options = {})
      @options = options
      @context = ScoutApm::AgentContext.new
    end

    def logger
      context.logger
    end

    # Finishes setting up the instrumentation, configuration, and attempts to start the agent.
    def install(force=false)
      context.config = ScoutApm::Config.with_file(context, context.config.value("config_file"))

      context.logger.info "Scout Agent [#{ScoutApm::VERSION}] Initialized"

      @instrument_manager = ScoutApm::InstrumentManager.new(context)
      @instrument_manager.install! if should_load_instruments? || force

      install_background_job_integrations
      install_app_server_integration

      logger.info "Scout Agent [#{ScoutApm::VERSION}] installed"

      context.installed!

      if ScoutApm::Agent::Preconditions.check?(context) || force
        # XXX: Should this happen at application start?
        # Should this ever happen after fork?
        # We start a thread in this, which can screw stuff up when we then fork.
        #
        # Save it into a variable to prevent it from ever running twice
        @app_server_load ||= AppServerLoad.new(context).run

        start
      end
    end

    # Unconditionally starts the agent. This includes verifying instruments are
    # installed, and starting the background worker.
    #
    # Does not attempt to start twice.
    def start(_opts={})
      if context.started?
        start_background_worker unless background_worker_running?
        return
      end

      install unless context.installed?

      context.started!

      log_environment

      start_background_worker
    end

    def log_environment
      bg_names = context.environment.background_job_integrations.map{|bg| bg.name }.join(", ")

      logger.info(
        "Scout Agent [#{ScoutApm::VERSION}] starting for [#{context.environment.application_name}] " +
        "Framework [#{context.environment.framework}] " +
        "App Server [#{context.environment.app_server}] " +
        "Background Job Framework [#{bg_names}] " +
        "Hostname [#{context.environment.hostname}]"
      )
    end

    # Attempts to install all background job integrations. This can come up if
    # an app has both Resque and Sidekiq - we want both to be installed if
    # possible, it's no harm to have the "wrong" one also installed while running.
    def install_background_job_integrations
      context.environment.background_job_integrations.each do |int|
        int.install
        logger.info "Installed Background Job Integration [#{int.name}]"
      end
    end

    # This sets up the background worker thread to run at the correct time,
    # either immediately, or after a fork into the actual unicorn/puma/etc
    # worker
    def install_app_server_integration
      context.environment.app_server_integration.install
      logger.info "Installed Application Server Integration [#{context.environment.app_server}]."
    end

    # If true, the agent will start regardless of safety checks.
    def force?
      @options[:force]
    end

    # The worker thread will automatically start UNLESS:
    # * A supported application server isn't detected (example: running via Rails console)
    # * A supported application server is detected, but it forks. In this case,
    #   the agent is started in the forked process.
    def start_background_worker?
      return true if force?
      return !context.environment.forking?
    end

    def should_load_instruments?
      return true if context.config.value('dev_trace')
      return false unless context.config.value('monitor')
      context.environment.app_server_integration.found? || context.environment.background_job_integrations.any?
    end

    #################################
    #  Background Worker Lifecycle  #
    #################################

    # Creates the worker thread. The worker thread is a loop that runs continuously. It sleeps for +Agent#period+ and when it wakes,
    # processes data, either saving it to disk or reporting to Scout.
    # => true if thread & worker got started
    # => false if it wasn't started (either due to already running, or other preconditions)
    def start_background_worker(quiet=false)
      if !context.config.value('monitor')
        logger.debug "Not starting background worker as monitoring isn't enabled." unless quiet
        return false
      end

      if background_worker_running?
        logger.info "Not starting background worker, already started" unless quiet
        return false
      end

      if context.shutting_down?
        logger.info "Not starting background worker, already in process of shutting down" unless quiet
        return false
      end

      logger.info "Initializing worker thread."

      ScoutApm::Agent::ExitHandler.new(context).install

      periodic_work = ScoutApm::PeriodicWork.new(context)

      @background_worker = ScoutApm::BackgroundWorker.new(context)
      @background_worker_thread = Thread.new do
        @background_worker.start {
          periodic_work.run
        }
      end

      return true
    end

    def stop_background_worker
      if @background_worker
        logger.info("Stopping background worker")
        @background_worker.stop
        context.store.write_to_layaway(context.layaway, :force)
        if @background_worker_thread.alive?
          @background_worker_thread.wakeup
          @background_worker_thread.join
        end
      end
    end

    def background_worker_running?
      @background_worker_thread          &&
        @background_worker_thread.alive? &&
        @background_worker               &&
        @background_worker.running?
    end
  end
end
