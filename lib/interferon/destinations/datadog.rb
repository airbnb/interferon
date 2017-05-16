require 'diffy'
require 'dogapi'
require 'parallel'
require 'set'
require 'thread'

Diffy::Diff.default_format = :text

module Interferon::Destinations
  class Datadog
    include ::Interferon::Logging

    attr_accessor :concurrency
    ALERT_KEY = 'Regards, [Robo Ops](https://instructure.atlassian.net/wiki/display/IOPS/Monitors).'

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

      # Datadog communication threads
      @concurrency = options['concurrency'] || 10
      # Fetch page size
      @page_size = options['page_size'] || 1000

      # configure retries
      @retries = options['retries'] || 3

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
    end

    def api_errors
      @api_errors ||= []
    end

    def generate_message(message, people)
      [message, ALERT_KEY, people.map{ |p| "@#{p}" }].flatten.join("\n")
    end

    def get_existing_alerts
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
            if alerts_page.length < @page_size
              has_more = false
            end
            alerts_page.map { |alert| alerts.push(alert) }
            successful = true
            break
          end
        end

        if !successful
          # Out of retries
          raise "Retries exceeded for fetching data from datadog."
        end
      end
      alerts.size.times.map { alerts.pop }
    end

    def existing_alerts
      unless @existing_alerts
        alerts = get_existing_alerts

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

      @existing_alerts
    end

    def create_alert(alert, people)
      # create a message which includes the notifications
      # Datadog may have a race condition where alerts created in a bad state may be triggered
      # during the dry-run creation process. Delete people from dry-run alerts to avoid this
      message = generate_message(alert['message'], people)

      # create the hash of options to send to datadog
      alert_options = {
        :notify_audit => alert['notify']['audit'],
        :notify_no_data => alert['notify_no_data'],
        :no_data_timeframe => alert['no_data_timeframe'],
        :silenced => alert['silenced'],
        :timeout_h => alert['timeout_h'],
      }

      if !alert['evaluation_delay'].nil?
        alert_options[:evaluation_delay] = alert['evaluation_delay']
      end

      if !alert['require_full_window'].nil?
        alert_options[:require_full_window] = alert['require_full_window']
      end

      if !alert['thresholds'].nil?
        alert_options[:thresholds] = alert['thresholds']
      end

      if !alert['include_tags'].nil?
        alert_options[:include_tags] = alert['include_tags']
      end

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
      if !(code >= 400 || code == -1)
        # assume this was a success
        @stats[:alerts_created] += 1 if action == :creating
        @stats[:alerts_updated] += 1 if action == :updating
        @stats[:alerts_silenced] += 1 if !alert_options[:silenced].empty?
      end

      id = resp[1].nil? ? nil : [resp[1]['id']]
      # lets key alerts by their name
      [alert['name'], id]
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

      @dog.monitor(
        alert['monitor_type'],
        datadog_query,
        :name => alert['name'],
        :message => @dry_run ? generate_message(alert, []) : message,
        :options => alert_options,
      )
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
        diff = Diffy::Diff.new(existing_alert_text, new_alert_text, :context=>1)
        log.info("updating existing alert #{id} (#{alert['name']}):\n#{diff}")

        if @dry_run
          resp = @dog.monitor(
            alert['monitor_type'],
            datadog_query,
            :name => alert['name'],
            :message => generate_message(alert, []),
            :options => alert_options,
          )
        else
          if alert['monitor_type'] == existing_alert['type']
            resp = @dog.update_monitor(
              id,
              datadog_query,
              :name => alert['name'],
              :message => message,
              :options => alert_options,
            )

            # Unmute existing alerts that have been unsilenced.
            # Datadog does not allow updates to silencing via the update_alert API call.
            if !existing_alert['options']['silenced'].empty? && alert_options[:silenced].empty?
              @dog.unmute_monitor(id)
            end
          else
            # Need to recreate alert with new monitor type
            resp = @dog.delete_monitor(id)
            code = resp[0].to_i
            if !(code >= 300 || code == -1)
              resp = @dog.monitor(
                alert['monitor_type'],
                datadog_query,
                :name => alert['name'],
                :message => message,
                :options => alert_options,
              )
            end
          end
        end
    resp
    end


    def remove_alert(alert)
      if alert['message'].include?(ALERT_KEY)
        @stats[:alerts_to_be_deleted] += 1
        log.info("deleting alert: #{alert['name']}")

        if !@dry_run
          alert['id'].each do |alert_id|
            resp = @dog.delete_monitor(alert_id)
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
      resp = @dog.delete_monitor(alert_id)
      code = resp[0].to_i
      log_datadog_response_code(resp, code, :deleting)
    end

    def log_datadog_response_code(resp, code, action, alert=nil)
      # log whenever we've encountered errors
      if code != 200 && !alert.nil?
        api_errors << "#{code} on alert #{alert['name']}"
      end

      # client error
      if code == 400
        @stats[:api_client_errors] += 1
        if !alert.nil?
          statsd.gauge('datadog.api.unknown_error', 0, :tags => ["alert:#{alert}"])
          statsd.gauge('datadog.api.client_error', 1, :tags => ["alert:#{alert}"])
          statsd.gauge('datadog.api.success', 0, :tags => ["alert:#{alert}"])
          log.error("client error while #{action} alert '#{alert['name']}';" \
                    " query was '#{alert['metric']['datadog_query']}'" \
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
                    " query was '#{alert['metric']['datadog_query']}'" \
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
