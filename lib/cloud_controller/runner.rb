require 'steno'
require 'json'
require 'optparse'
require 'cloud_controller/uaa/uaa_token_decoder'
require 'cloud_controller/uaa/uaa_verification_keys'
require 'app_log_emitter'
require 'loggregator_emitter'
require 'fluent_emitter'
require 'cloud_controller/rack_app_builder'
require 'cloud_controller/metrics/periodic_updater'
require 'cloud_controller/metrics/request_metrics'
require 'cloud_controller/telemetry_logger'
require 'cloud_controller/secrets_fetcher'
require 'net/http'

module VCAP::CloudController
  class Runner
    attr_reader :config, :config_file, :insert_seed_data, :secrets_file

    def initialize(argv)
      @argv = argv

      # default to production. this may be overridden during opts parsing
      ENV['NEW_RELIC_ENV'] ||= 'production'

      parse_options!
      secrets_hash = parse_secrets
      parse_config(secrets_hash)

      @log_counter = Steno::Sink::Counter.new
    end

    def logger
      setup_logging
      @logger ||= Steno.logger('cc.runner')
    end

    def options_parser
      @options_parser ||= OptionParser.new do |opts|
        opts.on('-c', '--config [ARG]', 'Configuration File') do |opt|
          @config_file = opt
        end
        opts.on('-s', '--secrets [ARG]', 'Secrets File') do |opt|
          @secrets_file = opt
        end
      end
    end

    def deprecation_warning(message)
      puts message
    end

    def parse_options!
      options_parser.parse!(@argv)
      raise 'Missing config' unless @config_file.present?
    rescue
      raise options_parser.to_s
    end

    def parse_secrets
      return {} unless secrets_file

      SecretsFetcher.fetch_secrets_from_file(secrets_file)
    rescue => e
      raise "ERROR: Failed loading secrets from file '#{secrets_file}': #{e}"
    end

    def parse_config(secrets_hash)
      @config = Config.load_from_file(config_file, context: :api, secrets_hash: secrets_hash)
    rescue Membrane::SchemaValidationError => ve
      raise "ERROR: There was a problem validating the supplied config: #{ve}"
    rescue => e
      raise "ERROR: Failed loading config from file '#{config_file}': #{e}"
    end

    def run!
      create_pidfile

      EM.run do
        start_cloud_controller

        request_metrics = VCAP::CloudController::Metrics::RequestMetrics.new(statsd_client)
        gather_periodic_metrics

        builder = RackAppBuilder.new
        app     = builder.build(@config, request_metrics)

        start_thin_server(app)
      rescue => e
        logger.error "Encountered error: #{e}\n#{e.backtrace.join("\n")}"
        raise e
      end
    end

    def run2!
      create_pidfile
      setup_logging
      setup_telemetry_logging
      setup_db
      @config.configure_components
      setup_app_log_emitter

      EM.run do
        k8s_api_client = CloudController::DependencyLocator.instance.k8s_api_client

        # loop do
        #   k8s_api_client.core_kube_client.watch_entities("events", field_selector: 'involvedObject.kind=LRP', namespace: "cf-workloads") do |notice|
        #     logger.info("Got lrp notification: #{notice}")
        #   end
        #   puts "exited, restarting..."
        # end

        uri = URI("#{k8s_api_client.config.kubernetes_host_url}/api/v1/watch/namespaces/cf-workloads/events\?fieldSelector\=involvedObject.kind\=LRP")
        h = Net::HTTP.new(uri.hostname, uri.port)
        h.set_debug_output($stdout)
        h.use_ssl = true
        h.read_timeout = 3600
        p k8s_api_client.config.kubernetes_ca_cert
        p k8s_api_client.config.get(:kubernetes, :ca_file)
        h.ca_file = k8s_api_client.config.get(:kubernetes, :ca_file)
        h.start do |http|
          puts "start started"

          req = Net::HTTP::Get.new(uri)
          req['Authorization'] = "Bearer #{k8s_api_client.config.kubernetes_service_account_token}"
          req['Contenty-Type'] = "application/json"
          req['Accept'] = "application/json"
          last = ''
          http.request(req) do |res|
            res.read_body do |chunk|
              p "chunk: #{chunk}"
              parse_events(last, chunk) do |event|
                p "yielded event: #{event}"
                instance_index = event['metadata']['labels']["cloudfoundry.org/instance_index"]
                process_guid = event['metadata']['annotations']["cloudfoundry.org/process_guid"]
                app_guid = Diego::ProcessGuid.cc_process_guid(process_guid)

                process = ProcessModel.find(guid: app_guid)
                raise CloudController::Errors::NotFound.new_from_details('ProcessNotFound', app_guid) unless process

                crash_payload = {
                  "index" => instance_index,
                  "instance" => event['metadata']['name'],
                  "reason" => event['reason'],
                  "exit_description" => event['message'],
                  "exit_status" => 999,
                  "crash_count" => event['count'],
                  "crash_timestamp" => DateTime.parse(event['lastTimestamp']).to_i
                }
                crash_payload['version'] = Diego::ProcessGuid.cc_process_version(process_guid)

                p "crash_payload #{crash_payload}"
                Repositories::ProcessEventRepository.record_crash(process, crash_payload)
                Repositories::AppEventRepository.new.create_app_exit_event(process, crash_payload)
              end
            end
          end
        end

        puts "start finished"
      rescue => e
        logger.error "Encountered error: #{e}\n#{e.backtrace.join("\n")}"
        raise e
      end
    end

    def parse_events(last, chunk)
      last, pieces = split_lines(last, chunk)
      p "last: #{last} , pieces: #{pieces}"
      pieces.each do |part|
        obj = JSON.parse(part)
        p "parsed object: #{obj}"
        yield obj['object']
      end
    end

    def split_lines(last, chunk)
      data = chunk
      data = last + '' + data

      ix = data.rindex("\n")
      return [data, []] unless ix

      complete = data[0..ix]
      last = data[(ix + 1)..data.length]
      [last, complete.split(/\n/)]
    end

    def gather_periodic_metrics
      logger.info('starting periodic metrics updater')
      periodic_updater.setup_updates
    end

    def trap_signals
      %w(TERM INT QUIT).each do |signal|
        trap(signal) do
          EM.add_timer(0) do
            logger.warn("Caught signal #{signal}")
            stop!
          end
        end
      end

      trap('USR1') do
        EM.add_timer(0) do
          logger.warn('Collecting diagnostics')
          collect_diagnostics
        end
      end
    end

    def stop!
      stop_thin_server
      logger.info('Stopping EventMachine')
      EM.stop
    end

    private

    def start_cloud_controller
      setup_logging
      setup_telemetry_logging
      setup_db
      setup_blobstore
      @config.configure_components

      setup_app_log_emitter
      @config.set(:external_host, VCAP::HostSystem.new.local_ip(@config.get(:local_route)))
    end

    def create_pidfile
      pid_file = VCAP::PidFile.new(@config.get(:pid_filename))
      pid_file.unlink_at_exit
    rescue
      raise "ERROR: Can't create pid file #{@config.get(:pid_filename)}"
    end

    def setup_logging
      return if @setup_logging

      @setup_logging = true

      StenoConfigurer.new(@config.get(:logging)).configure do |steno_config_hash|
        steno_config_hash[:sinks] << @log_counter
      end
    end

    def setup_telemetry_logging
      return if @setup_telemetry_logging

      @setup_telemetry_logging = true
      logger = ActiveSupport::Logger.new(@config.get(:telemetry_log_path))
      TelemetryLogger.init(logger)
    end

    def setup_db
      db_logger = Steno.logger('cc.db')
      DB.load_models(@config.get(:db), db_logger)
    end

    def setup_blobstore
      CloudController::DependencyLocator.instance.droplet_blobstore.ensure_bucket_exists
      CloudController::DependencyLocator.instance.package_blobstore.ensure_bucket_exists
      CloudController::DependencyLocator.instance.global_app_bits_cache.ensure_bucket_exists
      CloudController::DependencyLocator.instance.buildpack_blobstore.ensure_bucket_exists
    end

    def setup_app_log_emitter
      VCAP::AppLogEmitter.fluent_emitter = fluent_emitter if @config.get(:fluent)

      if @config.get(:loggregator) && @config.get(:loggregator, :router)
        VCAP::AppLogEmitter.emitter = LoggregatorEmitter::Emitter.new(@config.get(:loggregator, :router), 'cloud_controller', 'API', @config.get(:index))
      end

      VCAP::AppLogEmitter.logger = logger
    end

    def fluent_emitter
      VCAP::FluentEmitter.new(Fluent::Logger::FluentLogger.new(nil,
        host: @config.get(:fluent, :host) || 'localhost',
                port: @config.get(:fluent, :port) || 24224,
      ))
    end

    def start_thin_server(app)
      @thin_server = if @config.get(:nginx, :use_nginx)
                       Thin::Server.new(@config.get(:nginx, :instance_socket), signals: false)
                     else
                       Thin::Server.new(@config.get(:external_host), @config.get(:external_port), signals: false)
                     end

      @thin_server.app = app
      trap_signals

      # The routers proxying to us handle killing inactive connections.
      # Set an upper limit just to be safe.
      @thin_server.timeout = @config.get(:request_timeout_in_seconds)
      @thin_server.threaded = true
      @thin_server.threadpool_size = @config.get(:threadpool_size)
      logger.info("Starting thin server with #{EventMachine.threadpool_size} threads")
      @thin_server.start!
    end

    def stop_thin_server
      logger.info('Stopping Thin Server.')
      @thin_server.stop if @thin_server
    end

    def periodic_updater
      @periodic_updater ||= VCAP::CloudController::Metrics::PeriodicUpdater.new(
        Time.now.utc,
        @log_counter,
        Steno.logger('cc.api'),
        [
          VCAP::CloudController::Metrics::StatsdUpdater.new(statsd_client)
        ])
    end

    def statsd_client
      return @statsd_client if @statsd_client

      logger.info("configuring statsd server at #{@config.get(:statsd_host)}:#{@config.get(:statsd_port)}")
      Statsd.logger = Steno.logger('statsd.client')
      @statsd_client = Statsd.new(@config.get(:statsd_host), @config.get(:statsd_port))
    end

    def collect_diagnostics
      @diagnostics_dir ||= @config.get(:directories, :diagnostics)

      file = VCAP::CloudController::Diagnostics.new.collect(@diagnostics_dir)
      logger.warn("Diagnostics written to #{file}")
    rescue => e
      logger.warn("Failed to capture diagnostics: #{e}")
    end
  end
end
