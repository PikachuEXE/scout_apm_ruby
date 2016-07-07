module ScoutApm
  module Instruments
    class Grape
      attr_reader :logger

      def initalize(logger=ScoutApm::Agent.instance.logger)
        @logger = logger
        @installed = false
      end

      def installed?
        @installed
      end

      def install
        @installed = true

        if defined?(::Grape) && defined?(::Grape::Endpoint)
          ScoutApm::Agent.instance.logger.info "Instrumenting Grape::Endpoint"

          ::Grape::Endpoint.class_eval do
            include ScoutApm::Instruments::GrapeEndpointInstruments

            alias run_without_scout_instruments run
            alias run run_with_scout_instruments
          end
        end
      end
    end

    module GrapeEndpointInstruments
      def run_with_scout_instruments
        request = ::Grape::Request.new(env)
        req = ScoutApm::RequestManager.lookup
        path = ScoutApm::Agent.instance.config.value("uri_reporting") == 'path' ? request.path : request.fullpath
        req.annotate_request(:uri => path)

        # IP Spoofing Protection can throw an exception, just move on w/o remote ip
        req.context.add_user(:ip => request.ip) rescue nil

        req.set_headers(request.headers)
        req.web!

        name = ["Grape",
                self.options[:method].first,
                self.options[:for].to_s,
                self.namespace.sub(%r{\A/}, ''), # removing leading slashes
                self.options[:path].first,
        ].compact.map{ |n| n.to_s }.join("/")

        req.start_layer( ScoutApm::Layer.new("Controller", name) )
        begin
          run_without_scout_instruments
        rescue
          req.error!
          raise
        ensure
          req.stop_layer
        end
      end
    end
  end
end

