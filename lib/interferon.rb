require 'interferon/version'
require 'interferon/logging'

require 'interferon/loaders'

require 'interferon/alert'
require 'interferon/alert_dsl'

# require 'pry'  #uncomment if you're debugging
require 'erb'
require 'ostruct'
require 'parallel'
require 'set'
require 'yaml'

module Interferon
  class Interferon
    include Logging
    attr_accessor :host_sources, :destinations, :host_info

    DRY_RUN_ALERTS_NAME_PREFIX = '[-dry-run-]'.freeze

    # groups_sources is a hash from type => options for each group source
    # host_sources is a hash from type => options for each host source
    # destinations is a similar hash from type => options for each alerter
    def initialize(alerts_repo_path, groups_sources, host_sources, destinations,
                   dry_run = false, processes = nil)
      @alerts_repo_path = alerts_repo_path
      @groups_sources = groups_sources
      @host_sources = host_sources
      @destinations = destinations
      @dry_run = dry_run
      @processes = processes
      @request_shutdown = false
    end

    def run(dry_run = false)
      Signal.trap('TERM') do
        log.info 'SIGTERM received. shutting down gracefully...'
        @request_shutdown = true
      end
      @dry_run = dry_run
      run_desc = @dry_run ? 'dry run' : 'run'
      log.info "beginning alerts #{run_desc}"

      alerts = read_alerts
      groups = read_groups(@groups_sources)
      hosts = read_hosts(@host_sources)

      @destinations.each do |dest|
        dest['options'] ||= {}
        dest['options']['dry_run'] = true if @dry_run
      end

      update_alerts(@destinations, hosts, alerts, groups)

      if @request_shutdown
        log.info "interferon #{run_desc} shut down by SIGTERM"
      else
        log.info "interferon #{run_desc} complete"
      end
    end

    def read_alerts
      alerts = []
      failed = 0

      # validate that alerts path exists
      path = File.expand_path(File.join(@alerts_repo_path, 'alerts'))
      abort("no such directory #{path} for reading alert files") \
        unless Dir.exist?(path)

      Dir.glob(File.join(path, '*.rb')) do |alert_file|
        break if @request_shutdown
        begin
          alert = Alert.new(alert_file)
        rescue StandardError => e
          log.warn "error reading alert file #{alert_file}: #{e}"
          failed += 1
        else
          alerts << alert
        end
      end

      log.info "read #{alerts.count} alerts files from #{path}"

      statsd.gauge('alerts.read.count', alerts.count)
      statsd.gauge('alerts.read.failed', failed)

      abort("failed to read #{failed} alerts") if failed > 0
      alerts
    end

    def read_groups(sources)
      groups = {}
      loader = GroupSourcesLoader.new([@alerts_repo_path])
      loader.get_all(sources).each do |source|
        break if @request_shutdown
        source_groups = source.list_groups

        # add all people to groups
        people_count = 0
        source_groups.each do |name, people|
          groups[name] ||= []
          groups[name].concat(people)
          people_count += people.count
        end

        log.info "read #{people_count} people in #{source_groups.count} groups" \
                 "from source #{source.class.name}"
      end

      log.info "total of #{groups.values.flatten.count} people in #{groups.count} groups" \
               "from #{sources.count} sources"

      statsd.gauge('groups.sources', sources.count)
      statsd.gauge('groups.count', groups.count)
      statsd.gauge('groups.people', groups.values.flatten.count)

      groups
    end

    def read_hosts(sources)
      statsd.gauge('hosts.sources', sources.count)

      hosts = []
      loader = HostSourcesLoader.new([@alerts_repo_path])
      loader.get_all(sources).each do |source|
        break if @request_shutdown
        source_hosts = source.list_hosts
        hosts << source_hosts

        statsd.gauge('hosts.count', source_hosts.count, tags: ["source:#{source.class.name}"])
        log.info "read #{source_hosts.count} hosts from source #{source.class.name}"
      end

      hosts.flatten!
      log.info "total of #{hosts.count} entities from #{sources.count} sources"

      hosts
    end

    def update_alerts(destinations, hosts, alerts, groups)
      loader = DestinationsLoader.new([@alerts_repo_path])
      loader.get_all(destinations).each do |dest|
        break if @request_shutdown
        log.info "updating alerts on #{dest.class.name}"
        update_alerts_on_destination(dest, hosts, alerts, groups)
      end
    end

    def update_alerts_on_destination(dest, hosts, alerts, groups)
      # track some counters/stats per destination
      start_time = Time.new.to_f

      # get already-defined alerts
      existing_alerts = dest.existing_alerts

      if @dry_run
        do_dry_run_update(dest, hosts, alerts, existing_alerts, groups)
      else
        do_regular_update(dest, hosts, alerts, existing_alerts, groups)
      end

      unless @request_shutdown
        # run time summary
        run_time = Time.new.to_f - start_time
        statsd.histogram(
          @dry_run ? 'destinations.run_time.dry_run' : 'destinations.run_time',
          run_time,
          tags: ["destination:#{dest.class.name}"]
        )
        log.info "#{dest.class.name} : run completed in %.2f seconds" % run_time

        # report destination stats
        dest.report_stats
      end

      raise dest.api_errors.to_s if @dry_run && !dest.api_errors.empty?
    end

    def do_dry_run_update(dest, hosts, alerts, existing_alerts, groups)
      # Track these to clean up dry-run alerts from previous runs
      existing_dry_run_alerts = []
      existing_alerts.each do |name, alert|
        if name.start_with?(DRY_RUN_ALERTS_NAME_PREFIX)
          existing_dry_run_alerts << [alert['name'], [alert['id']]]
          existing_alerts.delete(name)
        end
      end

      alerts_queue = build_alerts_queue(hosts, alerts, groups)
      updates_queue = alerts_queue.reject do |_name, alert_people_pair|
        !Interferon.need_update(dest, alert_people_pair, existing_alerts)
      end

      # Add dry-run prefix to alerts and delete id to avoid impacting real alerts
      existing_alerts.keys.each do |name|
        existing_alert = existing_alerts[name]
        dry_run_alert_name = DRY_RUN_ALERTS_NAME_PREFIX + name
        existing_alert['name'] = dry_run_alert_name
        existing_alert['id'] = [nil]
        existing_alerts[dry_run_alert_name] = existing_alerts.delete(name)
      end

      # Build new queue with dry-run prefixes and ensure they are silenced
      alerts_queue.each do |_name, alert_people_pair|
        alert = alert_people_pair[0]
        dry_run_alert_name = DRY_RUN_ALERTS_NAME_PREFIX + alert['name']
        alert.change_name(dry_run_alert_name)
        alert.silence
      end

      # Create alerts in destination
      created_alerts = create_alerts(dest, updates_queue)

      # Existing alerts are pruned until all that remains are
      # alerts that aren't being generated anymore
      to_remove = existing_alerts.dup
      alerts_queue.each do |_name, alert_people_pair|
        alert = alert_people_pair[0]
        old_alerts = to_remove[alert['name']]

        next if old_alerts.nil?
        if old_alerts['id'].length == 1
          to_remove.delete(alert['name'])
        else
          old_alerts['id'] = old_alerts['id'].drop(1)
        end
      end

      # Clean up alerts not longer being generated
      to_remove.each do |_name, alert|
        break if @request_shutdown
        dest.remove_alert(alert)
      end

      # Clean up dry-run created alerts
      (created_alerts + existing_dry_run_alerts).each do |alert_id_pair|
        alert_ids = alert_id_pair[1]
        alert_ids.each do |alert_id|
          dest.remove_alert_by_id(alert_id)
        end
      end
    end

    def do_regular_update(dest, hosts, alerts, existing_alerts, groups)
      alerts_queue = build_alerts_queue(hosts, alerts, groups)
      updates_queue = alerts_queue.reject do |_name, alert_people_pair|
        !Interferon.need_update(dest, alert_people_pair, existing_alerts)
      end

      # Create alerts in destination
      create_alerts(dest, updates_queue)

      # Existing alerts are pruned until all that remains are
      # alerts that aren't being generated anymore
      to_remove = existing_alerts.dup
      alerts_queue.each do |_name, alert_people_pair|
        alert = alert_people_pair[0]
        old_alerts = to_remove[alert['name']]

        next if old_alerts.nil?
        if old_alerts['id'].length == 1
          to_remove.delete(alert['name'])
        else
          old_alerts['id'] = old_alerts['id'].drop(1)
        end
      end

      # Clean up alerts not longer being generated
      to_remove.each do |_name, alert|
        break if @request_shutdown
        dest.remove_alert(alert)
      end
    end

    def create_alerts(dest, alerts_queue)
      alert_key_ids = []
      alerts_to_create = alerts_queue.keys
      concurrency = dest.concurrency || 10
      unless @request_shutdown
        threads = Array.new(concurrency) do |i|
          log.info "thread #{i} created"
          t = Thread.new do
            while (name = alerts_to_create.shift)
              break if @request_shutdown
              cur_alert, people = alerts_queue[name]
              log.debug "creating alert for #{cur_alert[:name]}"
              alert_key_ids << dest.create_alert(cur_alert, people)
            end
          end
          t.abort_on_exception = true
          t
        end
        threads.map(&:join)
      end
      alert_key_ids
    end

    def build_alerts_queue(hosts, alerts, groups)
      alerts_queue = {}
      # create or update alerts; mark when we've done that
      result = Parallel.map(alerts, in_processes: @processes) do |alert|
        break if @request_shutdown
        alerts_generated = {}
        counters = {
          errors: 0,
          evals: 0,
          applies: 0,
          hosts: hosts.length,
        }
        last_eval_error = nil

        hosts.each do |hostinfo|
          begin
            alert.evaluate(hostinfo)
            counters[:evals] += 1
          rescue StandardError => e
            log.debug "Evaluation of alert #{alert} failed in the context of host #{hostinfo}"
            counters[:errors] += 1
            last_eval_error = e
            next
          end

          # don't define an alert that doesn't apply to this hostinfo
          unless alert[:applies]
            log.debug "alert #{alert[:name]} doesn't apply to #{hostinfo.inspect}"
            next
          end

          counters[:applies] += 1
          # don't define alerts twice
          next if alerts_generated.key?(alert[:name])

          # figure out who to notify
          people = Set.new(alert[:notify][:people])
          alert[:notify][:groups].each do |g|
            people += (groups[g] || [])
          end

          # queue the alert up for creation; we clone the alert to save the current state
          alerts_generated[alert[:name]] = [alert.clone, people]
        end

        # log some of the counters
        statsd.gauge('alerts.evaluate.errors', counters[:errors], tags: ["alert:#{alert}"])
        statsd.gauge('alerts.evaluate.applies', counters[:applies], tags: ["alert:#{alert}"])

        if counters[:applies] > 0
          log.info "alert #{alert} applies to #{counters[:applies]} of #{counters[:hosts]} hosts"
        end

        # did the alert fail to evaluate on all hosts?
        if counters[:errors] == counters[:hosts] && !last_eval_error.nil?
          log.error "alert #{alert} failed to evaluate in the context of all hosts!"
          log.error "last error on alert #{alert}: #{last_eval_error}"

          statsd.gauge('alerts.evaluate.failed_on_all', 1, tags: ["alert:#{alert}"])
          log.debug "alert #{alert}: " \
                    "error #{last_eval_error}\n#{last_eval_error.backtrace.join("\n")}"
        else
          statsd.gauge('alerts.evaluate.failed_on_all', 0, tags: ["alert:#{alert}"])
        end

        # did the alert apply to any hosts?
        if counters[:applies] == 0
          statsd.gauge('alerts.evaluate.never_applies', 1, tags: ["alert:#{alert}"])
          log.warn "alert #{alert} did not apply to any hosts"
        else
          statsd.gauge('alerts.evaluate.never_applies', 0, tags: ["alert:#{alert}"])
        end
        alerts_generated
      end

      result.each do |alerts_generated|
        alerts_queue.merge! alerts_generated
      end
      alerts_queue
    end

    def self.need_update(dest, alert_people_pair, existing_alerts_from_api)
      alert = alert_people_pair[0]
      existing = existing_alerts_from_api[alert['name']]
      if existing.nil?
        true
      else
        !same_alerts(dest, alert_people_pair, existing)
      end
    end

    def self.normalize_monitor_type(monitor_type)
      # Convert 'query alert' type to 'metric alert' type. They can used interchangeably when
      # submitting monitors to Datadog. Datadog will automatically do the conversion to 'query
      # alert' for a "complex" query that includes multiple metrics/tags while using 'metric alert'
      # for monitors that include a single scope/metric.
      monitor_type == 'query alert' ? 'metric alert' : monitor_type
    end

    def self.same_alerts(dest, alert_people_pair, alert_api_json)
      alert, people = alert_people_pair

      prev_alert = {
        monitor_type: normalize_monitor_type(alert_api_json['type']),
        query: alert_api_json['query'].strip,
        message: alert_api_json['message'].strip,
        evaluation_delay: alert_api_json['options']['evaluation_delay'],
        notify_no_data: alert_api_json['options']['notify_no_data'],
        notify_audit: alert_api_json['options']['notify_audit'],
        no_data_timeframe: alert_api_json['options']['no_data_timeframe'],
        silenced: alert_api_json['options']['silenced'],
        thresholds: alert_api_json['options']['thresholds'],
        timeout_h: alert_api_json['options']['timeout_h'],
      }

      new_alert = {
        monitor_type: normalize_monitor_type(alert['monitor_type']),
        query: alert['metric']['datadog_query'],
        message: dest.generate_message(alert['message'], people).strip,
        evaluation_delay: alert['evaluation_delay'],
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
  end
end
