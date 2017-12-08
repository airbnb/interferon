include ::Interferon::Logging

module Interferon::AlertSources
  class Filesystem
    def initialize(options)
      alert_types = options['alert_types']
      raise ArgumentError, 'missing alert_types for loading alerts from filesystem' \
        unless alert_types

      alert_types.each do |alert_type|
        raise ArgumentError, '"missing path for loading alerts from filesystem' \
          unless alert_type['path']
        raise ArgumentError, 'missing extention for loading alerts from filesystem' \
          unless alert_type['extension']
        raise ArgumentError, 'missing class for loading alerts from filesystem' \
          unless alert_type['class']
      end

      @alert_types = alert_types
    end

    def list_alerts
      alerts = []
      failed = 0

      @alert_types.each do |alert_type|
        # validate that alerts path exists
        path = File.expand_path(alert_type['path'])
        log.warn("No such directory #{path} for reading alert files") unless Dir.exist?(path)

        alert_class = Object.const_get("Interferon::#{alert_type['class']}")
        Dir.glob(File.join(path, alert_type['extension'])).each do |alert_file|
          break if @request_shutdown
          begin
            alert = alert_class.new(path, alert_file)
          rescue StandardError => e
            log.warn("Error reading alert file #{alert_file}: #{e}")
            failed += 1
          else
            alerts << alert
          end
        end

        log.info("Read #{alerts.count} alerts files from #{path}")
      end

      { alerts: alerts, failed: failed }
    end
  end
end
