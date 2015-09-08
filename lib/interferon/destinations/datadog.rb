require 'dogapi'
require 'set'

module Interferon::Destinations
  class Datadog
    include ::Interferon::Logging

    attr_accessor :concurrency
    ALERT_KEY = 'This alert was created via the alerts framework'

    def initialize(options)
      %w{app_key api_key}.each do |req|
        unless options[req]
          raise ArgumentError, "missing required argument #{req}"
        end
      end

      @dog = Dogapi::Client.new(options['api_key'], options['app_key'])
      @dry_run = !!options['dry_run']
      @existing_alerts = nil

      # create datadog alerts 10 at a time
      @concurrency = 10

      @stats = {
        :alerts_created => 0,
        :alerts_updated => 0,
        :alerts_deleted => 0,
        :alerts_silenced => 0,
        :api_successes => 0,
        :api_client_errors => 0,
        :api_unknown_errors => 0,
        :manually_created_alerts => 0,
      }
    end

    def existing_alerts
      unless @existing_alerts
        resp = @dog.get_all_alerts()
        alerts = resp[1]['alerts']

        # key alerts by name
        @existing_alerts = Hash[alerts.map{ |a| [a['name'], a] }]

        # count how many are manually created
        @stats[:manually_created_alerts] = \
          @existing_alerts.reject{|n,a| a['message'].include?(ALERT_KEY)}.length

        log.info "datadog: found %d existing alerts; %d were manually created" % [
          @existing_alerts.length,
          @stats[:manually_created_alerts],
        ]
      end

      return @existing_alerts
    end

    def create_alert(alert, people)
      # create a message which includes the notifications
      message = [
        alert['message'],
        ALERT_KEY,
        people.map{ |p| "@#{p}" }
      ].flatten.join("\n")

      # create the hash of options to send to datadog
      alert_opts = {
        :name => alert['name'],
        :message => message,
        :silenced => alert['silenced'] || alert['silenced_until'] > Time.now,
        :notify_no_data => alert['notify_no_data'],
        :notify_audit => alert['notify_audit'],
        :timeout_h => nil,
      }

      # allow an optional timeframe for "no data" alerts to be specified
      # (this feature is supported, even though it's not documented)
      alert_opts[:no_data_timeframe] = alert['no_data_timeframe'] if alert['no_data_timeframe']

      # timeout is in seconds, but set it to 1 hour at least
      alert_opts[:timeout_h] = [1, (alert['timeout'].to_i / 3600)].max if alert['timeout']

      # new alert, create it
      if existing_alerts[alert['name']].nil?
        action = :creating
        log.debug("new alert #{alert['name']}")

        resp = @dog.alert(
          alert['metric']['datadog_query'].strip,
          alert_opts,
        ) unless @dry_run

      # existing alert, modify it
      else
        action = :updating
        id = existing_alerts[alert['name']]['id']
        log.debug("updating existing alert #{id} (#{alert['name']})")

        resp = @dog.update_alert(
          id,
          alert['metric']['datadog_query'].strip,
          alert_opts
        ) unless @dry_run
      end

      # log whenever we've encountered errors
      code = @dry_run ? 200 : resp[0].to_i

      # client error
      if code == 400
        statsd.gauge('datadog.api.unknown_error', 0, :tags => ["alert:#{alert}"])
        statsd.gauge('datadog.api.client_error', 1, :tags => ["alert:#{alert}"])
        statsd.gauge('datadog.api.success', 0, :tags => ["alert:#{alert}"])

        @stats[:api_client_errors] += 1
        log.error("client error while #{action} alert '#{alert['name']}';" \
            " query was '#{alert['metric']['datadog_query'].strip}'")

      # unknown (prob. datadog) error:
      elsif code >= 400 || code == -1
        statsd.gauge('datadog.api.unknown_error', 1, :tags => ["alert:#{alert}"])
        statsd.gauge('datadog.api.client_error', 0, :tags => ["alert:#{alert}"])
        statsd.gauge('datadog.api.success', 0, :tags => ["alert:#{alert}"])

        @stats[:api_unknown_errors] += 1
        log.error("unknown error while #{action} alert '#{alert['name']}':" \
            " query was '#{alert['metric']['datadog_query'].strip}'" \
            " response was #{resp[0]}:'#{resp[1].inspect}'")

      # assume this was a success
      else
        statsd.gauge('datadog.api.unknown_error', 0, :tags => ["alert:#{alert}"])
        statsd.gauge('datadog.api.client_error', 0, :tags => ["alert:#{alert}"])
        statsd.gauge('datadog.api.success', 1, :tags => ["alert:#{alert}"])

        @stats[:api_successes] += 1
        @stats[:alerts_created] += 1 if action == :creating
        @stats[:alerts_updated] += 1 if action == :updating
        @stats[:alerts_silenced] += 1 if alert_opts[:silenced]
      end

      # lets key alerts by their name
      return alert['name']
    end

    def remove_alert(alert)
      if alert['message'].include?(ALERT_KEY)
        log.debug("deleting alert #{alert['id']} (#{alert['name']})")
        @dog.delete_alert(alert['id']) unless @dry_run
        @stats[:alerts_deleted] += 1
      else
        log.warn("not deleting manually-created alert #{alert['id']} (#{alert['name']})")
      end
    end

    def report_stats
      @stats.each do |k,v|
        statsd.gauge("datadog.#{k}", v)
      end

      log.info "datadog: created %d updated %d and deleted %d alerts" % [
        @stats[:alerts_created],
        @stats[:alerts_updated],
        @stats[:alerts_deleted],
      ]
    end
  end
end
