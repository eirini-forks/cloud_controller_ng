module VCAP::CloudController
  module Diego
    module ReporterMixins
      private

      def nanoseconds_to_seconds(time)
        (time / 1e9).to_i
      end

      def fill_unreported_instances_with_down_instances(reported_instances, process)
        down_instances = process.instances - reported_instances.length
        return reported_instances unless down_instances > 0

        for i in (0..down_instances) do
          reported_instances[i] = {
            state:  'DOWN',
            uptime: 0,
          }
        end

        reported_instances
      end
    end
  end
end
