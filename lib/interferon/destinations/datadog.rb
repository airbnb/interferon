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
    ALERT_KEY = 'This alert was created via the alerts framework'.freeze
    RETRYABLE_ERRORS = [Net::OpenTimeout, Net::ReadTimeout].freeze

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

      # will default to about 30 seconds over 6 retries
      @retry_base_delay = options['retry_base_delay'] || 0.3

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
      start_monitor, end_monitor = fetch_existing_alerts_boundaries

      # Edge case where they are equal.
      return [start_monitor] if start_monitor['id'] == end_monitor['id']

      # Another easy edge case when the span is like: monitor ids: [1, 2]
      return [start_monitor, end_monitor] if end_monitor['id'] - start_monitor['id'] == 1

      # Note: inclusive range is important here.
      range = (start_monitor['id']...end_monitor['id'])

      # Split this in divide and conquer-style. Build the ranges to iterate on in parallel to merge.
      # Build a list of queries for `id_offset=<id>` for which we can run concurrent requests with
      # consistent latency characteristics.
      queries = []

      range.step(@page_size) { |i| queries.push(i) }
      Parallel.map(queries, in_threads: @concurrency) do |start_monitor_id|
        successful = false
        @retries.downto(0) do
          options = { page_size: @page_size, id_offset: start_monitor_id, sort: 'ASC' }
          code, alerts_page = @dog.get_all_monitors(options)

          if code == 200
            alerts_page.each { |alert| alerts.push(alert) }
            successful = true
            break
          end

          log.info(
            <<-LOG_LINE
              Failed to retrieve existing alerts from datadog on id_offset=#{start_monitor_id}
              page_size=#{@page_size}. #{code}: #{alerts_page.inspect}
            LOG_LINE
          )
        end

        next if successful

        # Out of retries
        raise <<-EXCEPTION_LINE
          Retries exceeded for fetching data from datadog on id_offset=#{start_monitor_id}
          page_size=#{@page_size}
        EXCEPTION_LINE
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
        locked: alert['locked'],
      }

      unless alert['notify']['include_tags'].nil?
        alert_options[:include_tags] = alert['notify']['include_tags']
      end

      unless alert['notify']['renotify_interval'].nil?
        alert_options[:renotify_interval] = alert['notify']['renotify_interval']
      end

      unless alert['notify']['escalation_message'].nil?
        alert_options[:escalation_message] = alert['notify']['escalation_message']
      end

      unless alert['evaluation_delay'].nil?
        alert_options[:evaluation_delay] = alert['evaluation_delay']
      end

      alert_options[:new_host_delay] = alert['new_host_delay'] unless alert['new_host_delay'].nil?

      unless alert['require_full_window'].nil?
        alert_options[:require_full_window] = alert['require_full_window']
      end

      alert_options[:thresholds] = alert['thresholds'] unless alert['thresholds'].nil?

      tags = alert['tags'] || []

      datadog_query = alert['metric']['datadog_query']
      existing_alert = existing_alerts[alert['name']]

      # new alert, create it
      if existing_alert.nil?
        action = :creating
        resp = create_datadog_alert(alert, datadog_query, message, alert_options, tags)
      else
        # existing alert, modify it
        action = :updating
        resp = update_datadog_alert(alert, datadog_query, message,
                                    alert_options, tags, existing_alert)
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

    def create_datadog_alert(alert, datadog_query, message, alert_options, tags)
      @stats[:alerts_to_be_created] += 1
      new_alert_text = <<-MESSAGE
Query:
#{datadog_query}
Message:
#{message}
Tags:
#{tags.join(',')}
Options:
#{alert_options}
      MESSAGE
      log.info("creating new alert #{alert['name']}: #{new_alert_text}")

      monitor_options = {
        name: alert['name'],
        message: message,
        tags: tags,
        options: alert_options,
      }

      retryable do
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
    end

    def update_datadog_alert(alert, datadog_query, message, alert_options, tags, existing_alert)
      @stats[:alerts_to_be_updated] += 1
      id = existing_alert['id'][0]

      new_alert_text = <<-MESSAGE.strip
Query:
#{datadog_query.strip}
Message:
#{message.strip}
Tags:
#{tags.join(',')}
Options:
#{alert_options}
      MESSAGE
      existing_alert_text = <<-MESSAGE.strip
Query:
#{existing_alert['query'].strip}
Message:
#{existing_alert['message'].strip}
Tags:
#{existing_alert['tags'].join(',')}
Options:
#{alert_options}
      MESSAGE
      diff = Diffy::Diff.new(existing_alert_text, new_alert_text, context: 1)
      log.info("updating existing alert #{id} (#{alert['name']}):\n#{diff}")

      monitor_options = {
        name: alert['name'],
        message: message,
        tags: tags,
        options: alert_options,
      }

      resp = ''
      if @dry_run
        retryable do
          resp = @dog.validate_monitor(
            alert['monitor_type'],
            datadog_query,
            monitor_options
          )
        end
      elsif self.class.same_monitor_type(alert['monitor_type'], existing_alert['type'])
        retryable do
          resp = @dog.update_monitor(
            id,
            datadog_query,
            monitor_options
          )
        end

        # Unmute existing alerts that exceed the max silenced time
        # Datadog does not allow updates to silencing via the update_alert API call.
        silenced = existing_alert['options']['silenced']
        if !@max_mute_minutes.nil?
          silenced = silenced.values.reject do |t|
            t.nil? || t == '*' || t > Time.now.to_i + @max_mute_minutes * 60
          end
          retryable do
            @dog.unmute_monitor(id) if alert_options[:silenced].empty? && silenced.empty?
          end
        elsif alert_options[:silenced].empty? && !silenced.empty?
          retryable do
            @dog.unmute_monitor(id)
          end
        end
      else
        # Need to recreate alert with new monitor type
        retryable do
          resp = @dog.delete_monitor(id)
        end

        code = resp[0].to_i
        unless code >= 300 || code == -1
          retryable do
            resp = @dog.monitor(
              alert['monitor_type'],
              datadog_query,
              monitor_options
            )
          end
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
        resp = ''
        retryable do
          resp = @dog.delete_monitor(alert_id)
        end
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
        escalation_message: alert_api_json['options']['escalation_message'],
        evaluation_delay: alert_api_json['options']['evaluation_delay'],
        new_host_delay: alert_api_json['options']['new_host_delay'],
        include_tags: alert_api_json['options']['include_tags'],
        notify_no_data: alert_api_json['options']['notify_no_data'],
        notify_audit: alert_api_json['options']['notify_audit'],
        no_data_timeframe: alert_api_json['options']['no_data_timeframe'],
        renotify_interval: alert_api_json['options']['renotify_interval'],
        silenced: alert_api_json['options']['silenced'],
        thresholds: alert_api_json['options']['thresholds'],
        timeout_h: alert_api_json['options']['timeout_h'],
        locked: alert_api_json['options']['locked'],
        tags: alert_api_json['tags'],
      }

      new_alert = {
        monitor_type: self.class.normalize_monitor_type(alert['monitor_type']),
        query: alert['metric']['datadog_query'],
        message: generate_message(
          alert['message'],
          people,
          notify_recovery: alert['notify']['recovery']
        ).strip,
        escalation_message: alert['notify']['escalation_message'],
        evaluation_delay: alert['evaluation_delay'],
        new_host_delay: alert['new_host_delay'],
        include_tags: alert['notify']['include_tags'],
        notify_no_data: alert['notify_no_data'],
        notify_audit: alert['notify']['audit'],
        no_data_timeframe: alert['no_data_timeframe'],
        renotify_interval: alert['notify']['renotify_interval'],
        silenced: alert['silenced'],
        thresholds: alert['thresholds'],
        timeout_h: alert['timeout_h'],
        locked: alert['locked'],
        tags: alert['tags'],
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
        'datadog: successfully created (%<alerts_created>d/%<alerts_to_be_created>d),' \
        'updated (%<alerts_updated>d/%<alerts_to_be_updated>d),' \
        'and deleted (%<alerts_deleted>d/%<alerts_to_be_deleted>d) alerts' % @stats
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

    def retryable(retries = 0, &block)
      yield
    rescue *RETRYABLE_ERRORS => e
      raise e unless retries < @retries

      sleep(2**retries * @retry_base_delay)
      retryable(retries + 1, &block)
    end

    private

    def fetch_existing_alerts_boundaries
      # We need to obtain the monitor id boundary conditions.
      start_monitor = nil
      end_monitor = nil

      # Get the first monitor.
      @retries.downto(0) do
        options = { page_size: 1, sort: 'ASC' }
        code, monitors = @dog.get_all_monitors(options)

        if code == 200 && !monitors.empty?
          start_monitor = monitors[0]
          break
        end

        log.info("Failed to retrieve start monitor from datadog. #{code}: #{monitors.inspect}")
      end

      raise 'Unable to find first monitor' if start_monitor.nil?

      # Get the last monitor.
      @retries.downto(0) do
        options = { page_size: 1, sort: 'DESC' }
        code, monitors = @dog.get_all_monitors(options)

        if code == 200 && !monitors.empty?
          end_monitor = monitors[0]
          break
        end

        log.info("Failed to retrieve end monitor from datadog. #{code}: #{monitors.inspect}")
      end

      raise 'Unable to find last monitor id' if end_monitor.nil?

      [start_monitor, end_monitor]
    end
  end
end
