require 'diffy'
require 'dogapi'
require 'set'
require 'treetop'

Treetop.load 'datadog.treetop'

Diffy::Diff.default_format = :text

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

      # Set dogapi timeout explicitly
      api_timeout = options['api_timeout'] || 15

      # Default parameters of Dogapi Client initialize() can be referenced from link below:
      # (as of this writing)
      # https://github.com/DataDog/dogapi-rb/blob/master/lib/dogapi/facade.rb#L14
      args = [
        options['api_key'],
        options['app_key'],
        nil, # host to talk to
        nil, # device
        true, # silent?
        api_timeout, # API timeout
      ]
      @dog = Dogapi::Client.new(*args)

      @existing_alerts = nil
      @dry_run = options['dry_run']

      # create datadog alerts 10 at a time
      @concurrency = 10

      @stats = {
        :alerts_created => 0,
        :alerts_to_be_created => 0,
        :alerts_updated => 0,
        :alerts_to_be_updated => 0,
        :alerts_deleted => 0,
        :alerts_to_be_deleted => 0,
        :alerts_silenced => 0,
        :api_successes => 0,
        :api_client_errors => 0,
        :api_unknown_errors => 0,
        :manually_created_alerts => 0,
      }

      @datadog_query_parser = DatadogQueryParser.new
    end

    def api_errors
      @api_errors ||= []
    end

    def generate_message(message, people)
      [message, ALERT_KEY, people.map{ |p| "@#{p}" }].flatten.join("\n")
    end

    def existing_alerts
      unless @existing_alerts
        resp = @dog.get_all_alerts()

        code = resp[0].to_i
        if code != 200
          raise "Failed to retrieve existing alerts from datadog. #{code.to_s}: #{resp[1].inspect}"
        end

        alerts = resp[1]['alerts']

        # key alerts by name
        @existing_alerts = {}
        alerts.each do |alert|
          existing_alert = @existing_alerts[alert['name']]
          if existing_alert.nil?
            alert['id'] = [alert['id']]
            @existing_alerts[alert['name']] = alert
          else
            existing_alert['id'] << alert['id']
          end
        end

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
      message = generate_message(alert['message'], people)

      # create the hash of options to send to datadog
      alert_opts = {
        :name => alert['name'],
        :message => message,
        :silenced => alert['silenced'] || alert['silenced_until'] > Time.now,
        :notify_no_data => alert['notify_no_data'],
        :timeout_h => nil,
      }

      # allow an optional timeframe for "no data" alerts to be specified
      # (this feature is supported, even though it's not documented)
      alert_opts[:no_data_timeframe] = alert['no_data_timeframe'] if alert['no_data_timeframe']

      # timeout is in seconds, but set it to 1 hour at least
      alert_opts[:timeout_h] = [1, (alert['timeout'].to_i / 3600)].max if alert['timeout']

      datadog_query = alert['metric']['datadog_query'].strip
      existing_alert = existing_alerts[alert['name']]

      if @datadog_query_parser.parse(datadog_query.split.join('')).nil?
        log.warn "Invalid datadog query in #{alert['name']}: #{datadog_query} #{@datadog_query_parser.failure_reason}"
      end

      # new alert, create it
      if existing_alert.nil?
        action = :creating
        @stats[:alerts_to_be_created] += 1
        new_alert_text = "Query: #{datadog_query} Message: #{message.split().join(' ')}"
        log.info("creating new alert #{alert['name']}: #{new_alert_text}")

        resp = @dog.alert(
          alert['metric']['datadog_query'].strip,
          alert_opts,
        )

      # existing alert, modify it
      else
        action = :updating
        @stats[:alerts_to_be_updated] += 1
        id = existing_alert['id'][0]

        new_alert_text = "Query:\n#{datadog_query}\nMessage:\n#{message}"
        existing_alert_text = "Query:\n#{existing_alert['query']}\nMessage:\n#{existing_alert['message']}\n"
        diff = Diffy::Diff.new(existing_alert_text, new_alert_text, :context=>1)
        log.info("updating existing alert #{id} (#{alert['name']}): #{diff}")

        if @dry_run
          resp = @dog.alert(
            alert['metric']['datadog_query'].strip,
            alert_opts,
          )
        else
          resp = @dog.update_alert(
            id,
            alert['metric']['datadog_query'].strip,
            alert_opts
          )
        end
      end

      # log whenever we've encountered errors
      code = resp[0].to_i
      log_datadog_response_code(resp, code, action, alert)

      # assume this was a success
      if !(code >= 400 || code == -1)
        # assume this was a success
        @stats[:alerts_created] += 1 if action == :creating
        @stats[:alerts_updated] += 1 if action == :updating
        @stats[:alerts_silenced] += 1 if alert_opts[:silenced]
      end

      id = resp[1].nil? ? nil : [resp[1]['id']]
      # lets key alerts by their name
      return [alert['name'], id]
    end

    def remove_alert(alert)
      if alert['message'].include?(ALERT_KEY)
        @stats[:alerts_to_be_deleted] += 1
        log.info("deleting alert: #{alert['name']}")

        if not @dry_run
          alert['id'].each do |alert_id|
            resp = @dog.delete_alert(alert_id)
            code = resp[0].to_i
            log_datadog_response_code(resp, code, :deleting)

            if !(code >= 300 || code == -1)
              # assume this was a success
              @stats[:alerts_deleted] += 1
            end
          end
        end
      else
        log.warn("not deleting manually-created alert #{alert['id']} (#{alert['name']})")
      end
    end

    def report_stats
      @stats.each do |k,v|
        statsd.gauge("datadog.#{k}", v)
      end

      log.info "datadog: successfully created (%d/%d), updated (%d/%d), and deleted (%d/%d) alerts" % [
        @stats[:alerts_created],
        @stats[:alerts_to_be_created],
        @stats[:alerts_updated],
        @stats[:alerts_to_be_updated],
        @stats[:alerts_deleted],
        @stats[:alerts_to_be_deleted],
      ]
    end

    def remove_alert_by_id(alert_id)
      # This should only be used by dry-run to clean up created dry-run alerts
      log.debug("deleting alert, id: #{alert_id}")
      resp = @dog.delete_alert(alert_id)
      code = resp[0].to_i
      log_datadog_response_code(resp, code, :deleting)
    end

    def log_datadog_response_code(resp, code, action, alert=nil)
      # log whenever we've encountered errors
      if code != 200 and !alert.nil?
        api_errors << "#{code.to_s} on alert #{alert['name']}"
      end

      # client error
      if code == 400
        @stats[:api_client_errors] += 1
        if !alert.nil?
          statsd.gauge('datadog.api.unknown_error', 0, :tags => ["alert:#{alert}"])
          statsd.gauge('datadog.api.client_error', 1, :tags => ["alert:#{alert}"])
          statsd.gauge('datadog.api.success', 0, :tags => ["alert:#{alert}"])
          log.error("client error while #{action} alert '#{alert['name']}';" \
                    " query was '#{alert['metric']['datadog_query'].strip}'" \
                    " response was #{resp[0]}:'#{resp[1].inspect}'")
        end

        # unknown (prob. datadog) error:
      elsif code > 400 || code == -1
        @stats[:api_unknown_errors] += 1
        if !alert.nil?
          statsd.gauge('datadog.api.unknown_error', 1, :tags => ["alert:#{alert}"])
          statsd.gauge('datadog.api.client_error', 0, :tags => ["alert:#{alert}"])
          statsd.gauge('datadog.api.success', 0, :tags => ["alert:#{alert}"])
          log.error("unknown error while #{action} alert '#{alert['name']}':" \
                    " query was '#{alert['metric']['datadog_query'].strip}'" \
                    " response was #{resp[0]}:'#{resp[1].inspect}'")
        end
      else
        @stats[:api_successes] += 1
        if !alert.nil?
          statsd.gauge('datadog.api.unknown_error', 0, :tags => ["alert:#{alert}"])
          statsd.gauge('datadog.api.client_error', 0, :tags => ["alert:#{alert}"])
          statsd.gauge('datadog.api.success', 1, :tags => ["alert:#{alert}"])
        end
      end
    end

  end
end
