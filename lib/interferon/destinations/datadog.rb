# frozen_string_literal: true

require 'diffy'
require 'dogapi'
require 'parallel'
require 'set'
Diffy::Diff.default_format = :text

module Interferon::Destinations
  class Datadog
    include ::Interferon::Logging

    attr_accessor :concurrency
    attr_reader :alert_key
    ALERT_KEY = 'This alert was created via the alerts framework'

    def initialize(options)
      %w[app_key api_key].each do |req|
        raise ArgumentError, "missing required argument #{req}" unless options[req]
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
      @max_mute_minutes = options['max_mute_minutes']
      @dry_run = options['dry_run']
      @alert_key = options['alert_key'] || ALERT_KEY

      # Datadog communication threads
      @concurrency = options['concurrency'] || 10
      # Fetch page size
      @page_size = options['page_size'] || 1000

      # configure retries
      @retries = options['retries'] || 3

      @stats = {
        alerts_created: 0,
        alerts_to_be_created: 0,
        alerts_updated: 0,
        alerts_to_be_updated: 0,
        alerts_deleted: 0,
        alerts_to_be_deleted: 0,
        alerts_silenced: 0,
        api_successes: 0,
        api_client_errors: 0,
        api_unknown_errors: 0,
        manually_created_alerts: 0,
      }
    end

    def api_errors
      @api_errors ||= []
    end

    def generate_message(message, people, options = {})
      mentions = people.sort.map { |p| "@#{p}" }

      unless options[:notify_recovery]
        # Only mention on alert/warning
        mentions = "{{^is_recovery}}#{mentions}{{/is_recovery}}"
      end

      [message, alert_key, mentions].flatten.join("\n")
    end

    def fetch_existing_alerts
      alerts = Queue.new
      has_more = true

      Parallel.map_with_index(-> { has_more || Parallel::Stop },
                              in_threads: @concurrency) do |_, page|
        successful = false
        @retries.downto(0) do
          resp = @dog.get_all_monitors(page: page, page_size: @page_size)
          code = resp[0].to_i
          if code != 200
            log.info("Failed to retrieve existing alerts from datadog. #{code}: #{resp[1].inspect}")
          else
            alerts_page = resp[1]
            has_more = false if alerts_page.length < @page_size
            alerts_page.map { |alert| alerts.push(alert) }
            successful = true
            break
          end
        end

        unless successful
          # Out of retries
          raise 'Retries exceeded for fetching data from datadog.'
        end
      end
      Array.new(alerts.size) { alerts.pop }
    end

    def existing_alerts
      unless @existing_alerts
        alerts = fetch_existing_alerts

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
          @existing_alerts.reject { |_n, a| a['message'].include?(alert_key) }.length

        log.info(
          "datadog: found #{@existing_alerts.length} existing alerts; " \
          "#{@stats[:manually_created_alerts]} were manually created"
        )
      end

      @existing_alerts
    end

    def create_alert(alert, people)
      # create a message which includes the notifications
      # Datadog may have a race condition where alerts created in a bad state may be triggered
      # during the dry-run creation process. Delete people from dry-run alerts to avoid this
      message = generate_message(
        alert['message'],
        people,
        notify_recovery: alert['notify']['recovery']
      )

      # create the hash of options to send to datadog
      alert_options = {
        notify_audit: alert['notify']['audit'],
        notify_no_data: alert['notify_no_data'],
        no_data_timeframe: alert['no_data_timeframe'],
        silenced: alert['silenced'],
        timeout_h: alert['timeout_h'],
      }

      unless alert['notify']['include_tags'].nil?
        alert_options[:include_tags] = alert['notify']['include_tags']
      end

      unless alert['evaluation_delay'].nil?
        alert_options[:evaluation_delay] = alert['evaluation_delay']
      end

      alert_options[:new_host_delay] = alert['new_host_delay'] unless alert['new_host_delay'].nil?

      unless alert['require_full_window'].nil?
        alert_options[:require_full_window] = alert['require_full_window']
      end

      alert_options[:thresholds] = alert['thresholds'] unless alert['thresholds'].nil?

      datadog_query = alert['metric']['datadog_query']
      existing_alert = existing_alerts[alert['name']]

      # new alert, create it
      if existing_alert.nil?
        action = :creating
        resp = create_datadog_alert(alert, datadog_query, message, alert_options)
      else
        # existing alert, modify it
        action = :updating
        resp = update_datadog_alert(alert, datadog_query, message, alert_options, existing_alert)
      end

      # log whenever we've encountered errors
      code = resp[0].to_i
      log_datadog_response_code(resp, code, action, alert)

      # assume this was a success
      unless code >= 400 || code == -1
        # assume this was a success
        @stats[:alerts_created] += 1 if action == :creating
        @stats[:alerts_updated] += 1 if action == :updating
        @stats[:alerts_silenced] += 1 unless alert_options[:silenced].empty?
      end

      # lets key alerts by their name
      alert['name']
    end

    def create_datadog_alert(alert, datadog_query, message, alert_options)
      @stats[:alerts_to_be_created] += 1
      new_alert_text = <<-EOM
Query:
#{datadog_query}
Message:
#{message}
Options:
#{alert_options}
EOM
      log.info("creating new alert #{alert['name']}: #{new_alert_text}")

      monitor_options = {
        name: alert['name'],
        message: message,
        options: alert_options,
      }

      if @dry_run
        @dog.validate_monitor(
          alert['monitor_type'],
          datadog_query,
          monitor_options
        )
      else
        @dog.monitor(
          alert['monitor_type'],
          datadog_query,
          monitor_options
        )
      end
    end

    def update_datadog_alert(alert, datadog_query, message, alert_options, existing_alert)
      @stats[:alerts_to_be_updated] += 1
      id = existing_alert['id'][0]

      new_alert_text = <<-EOM.strip
Query:
#{datadog_query.strip}
Message:
#{message.strip}
Options:
#{alert_options}
EOM
      existing_alert_text = <<-EOM.strip
Query:
#{existing_alert['query'].strip}
Message:
#{existing_alert['message'].strip}
Options:
#{alert_options}
EOM
      diff = Diffy::Diff.new(existing_alert_text, new_alert_text, context: 1)
      log.info("updating existing alert #{id} (#{alert['name']}):\n#{diff}")

      monitor_options = {
        name: alert['name'],
        message: message,
        options: alert_options,
      }

      if @dry_run
        resp = @dog.validate_monitor(
          alert['monitor_type'],
          datadog_query,
          monitor_options
        )
      elsif self.class.same_monitor_type(alert['monitor_type'], existing_alert['type'])
        resp = @dog.update_monitor(
          id,
          datadog_query,
          monitor_options
        )

        # Unmute existing alerts that exceed the max silenced time
        # Datadog does not allow updates to silencing via the update_alert API call.
        silenced = existing_alert['options']['silenced']
        if !@max_mute_minutes.nil?
          silenced = silenced.values.reject do |t|
            t.nil? || t == '*' || t > Time.now.to_i + @max_mute_minutes * 60
          end
          @dog.unmute_monitor(id) if alert_options[:silenced].empty? && silenced.empty?
        elsif alert_options[:silenced].empty? && !silenced.empty?
          @dog.unmute_monitor(id)
        end
      else
        # Need to recreate alert with new monitor type
        resp = @dog.delete_monitor(id)
        code = resp[0].to_i
        unless code >= 300 || code == -1
          resp = @dog.monitor(
            alert['monitor_type'],
            datadog_query,
            monitor_options
          )
        end
      end
      resp
    end

    def remove_alert(alert)
      if alert['message'].include?(alert_key)
        @stats[:alerts_to_be_deleted] += 1
        log.info("deleting alert: #{alert['name']}")

        # Safety to protect aginst accident dry_run deletion
        remove_datadog_alert(alert) unless @dry_run
      else
        log.warn("not deleting manually-created alert #{alert['id']} (#{alert['name']})")
      end
    end

    def remove_datadog_alert(alert)
      alert['id'].each do |alert_id|
        resp = @dog.delete_monitor(alert_id)
        code = resp[0].to_i
        log_datadog_response_code(resp, code, :deleting)

        unless code >= 300 || code == -1
          # assume this was a success
          @stats[:alerts_deleted] += 1
        end
      end
    end

    def need_update(alert_people_pair, existing_alerts_from_api)
      alert, people = alert_people_pair
      existing = existing_alerts_from_api[alert['name']]
      existing.nil? || !same_alerts(alert, people, existing)
    end

    def self.normalize_monitor_type(monitor_type)
      # Convert 'query alert' type to 'metric alert' type. They can used interchangeably when
      # submitting monitors to Datadog. Datadog will automatically do the conversion to 'query
      # alert' for a "complex" query that includes multiple metrics/tags while using 'metric alert'
      # for monitors that include a single scope/metric.
      monitor_type == 'query alert' ? 'metric alert' : monitor_type
    end

    def self.same_monitor_type(monitor_type_a, monitor_type_b)
      normalize_monitor_type(monitor_type_a) == normalize_monitor_type(monitor_type_b)
    end

    def same_alerts(alert, people, alert_api_json)
      prev_alert = {
        monitor_type: self.class.normalize_monitor_type(alert_api_json['type']),
        query: alert_api_json['query'].strip,
        message: alert_api_json['message'].strip,
        evaluation_delay: alert_api_json['options']['evaluation_delay'],
        new_host_delay: alert_api_json['options']['new_host_delay'],
        include_tags: alert_api_json['options']['include_tags'],
        notify_no_data: alert_api_json['options']['notify_no_data'],
        notify_audit: alert_api_json['options']['notify_audit'],
        no_data_timeframe: alert_api_json['options']['no_data_timeframe'],
        silenced: alert_api_json['options']['silenced'],
        thresholds: alert_api_json['options']['thresholds'],
        timeout_h: alert_api_json['options']['timeout_h'],
      }

      new_alert = {
        monitor_type: self.class.normalize_monitor_type(alert['monitor_type']),
        query: alert['metric']['datadog_query'],
        message: generate_message(
          alert['message'],
          people,
          notify_recovery: alert['notify']['recovery']
        ).strip,
        evaluation_delay: alert['evaluation_delay'],
        new_host_delay: alert['new_host_delay'],
        include_tags: alert['notify']['include_tags'],
        notify_no_data: alert['notify_no_data'],
        notify_audit: alert['notify']['audit'],
        no_data_timeframe: alert['no_data_timeframe'],
        silenced: alert['silenced'],
        thresholds: alert['thresholds'],
        timeout_h: alert['timeout_h'],
      }

      unless alert['require_full_window'].nil?
        prev_alert[:require_full_window] = alert_api_json['options']['require_full_window']
        new_alert[:require_full_window] = alert['require_full_window']
      end

      prev_alert == new_alert
    end

    def report_stats
      @stats.each do |k, v|
        statsd.gauge("datadog.#{k}", v)
      end

      log.info(
        'datadog: successfully created (%d/%d), updated (%d/%d), and deleted (%d/%d) alerts' % [
          @stats[:alerts_created],
          @stats[:alerts_to_be_created],
          @stats[:alerts_updated],
          @stats[:alerts_to_be_updated],
          @stats[:alerts_deleted],
          @stats[:alerts_to_be_deleted],
        ]
      )
    end

    def log_datadog_response_code(resp, code, action, alert = nil)
      # log whenever we've encountered errors
      api_errors << "#{code} on alert #{alert['name']}" if code != 200 && !alert.nil?

      # client error
      if code == 400
        @stats[:api_client_errors] += 1
        unless alert.nil?
          statsd.gauge('datadog.api.unknown_error', 0, tags: ["alert:#{alert}"])
          statsd.gauge('datadog.api.client_error', 1, tags: ["alert:#{alert}"])
          statsd.gauge('datadog.api.success', 0, tags: ["alert:#{alert}"])
          log.error("client error while #{action} alert '#{alert['name']}';" \
                    " query was '#{alert['metric']['datadog_query']}'" \
                    " response was #{resp[0]}:'#{resp[1].inspect}'")
        end

      # unknown (prob. datadog) error:
      elsif code > 400 || code == -1
        @stats[:api_unknown_errors] += 1
        unless alert.nil?
          statsd.gauge('datadog.api.unknown_error', 1, tags: ["alert:#{alert}"])
          statsd.gauge('datadog.api.client_error', 0, tags: ["alert:#{alert}"])
          statsd.gauge('datadog.api.success', 0, tags: ["alert:#{alert}"])
          log.error("unknown error while #{action} alert '#{alert['name']}':" \
                    " query was '#{alert['metric']['datadog_query']}'" \
                    " response was #{resp[0]}:'#{resp[1].inspect}'")
        end
      else
        @stats[:api_successes] += 1
        unless alert.nil?
          statsd.gauge('datadog.api.unknown_error', 0, tags: ["alert:#{alert}"])
          statsd.gauge('datadog.api.client_error', 0, tags: ["alert:#{alert}"])
          statsd.gauge('datadog.api.success', 1, tags: ["alert:#{alert}"])
        end
      end
    end
  end
end
