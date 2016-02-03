require 'interferon/version'
require 'interferon/logging'

require 'interferon/loaders'

require 'interferon/alert'
require 'interferon/alert_dsl'

#require 'pry'  #uncomment if you're debugging
require 'erb'
require 'ostruct'
require 'set'
require 'yaml'

module Interferon
  class Interferon

    include Logging
    attr_accessor :host_sources, :destinations, :host_info

    DRY_RUN_ALERTS_NAME_PREFIX = '[-dry-run-]'

    # groups_sources is a hash from type => options for each group source
    # host_sources is a hash from type => options for each host source
    # destinations is a similiar hash from type => options for each alerter
    def initialize(alerts_repo_path, groups_sources, host_sources, destinations)
      @alerts_repo_path = alerts_repo_path
      @groups_sources = groups_sources
      @host_sources = host_sources
      @destinations = destinations
      @request_shutdown = false
    end

    def run(dry_run = false)
      Signal.trap("TERM") do
        log.info "SIGTERM received. shutting down gracefully..."
        @request_shutdown = true
      end
      run_desc = dry_run ? 'dry run' : 'run'
      log.info "beginning alerts #{run_desc}"

      alerts = read_alerts
      groups = read_groups(@groups_sources)
      hosts = read_hosts(@host_sources)

      @destinations.each do |dest|
        dest['options'] ||= {}
      end

      update_alerts(@destinations, hosts, alerts, groups, dry_run)

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
        unless Dir.exists?(path)

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
      return alerts
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

        log.info "read #{people_count} people in #{source_groups.count} groups from source #{source.class.name}"
      end

      log.info "total of #{groups.values.flatten.count} people in #{groups.count} groups from #{sources.count} sources"

      statsd.gauge('groups.sources', sources.count)
      statsd.gauge('groups.count', groups.count)
      statsd.gauge('groups.people', groups.values.flatten.count)

      return groups
    end

    def read_hosts(sources)
      statsd.gauge('hosts.sources', sources.count)

      hosts = []
      loader = HostSourcesLoader.new([@alerts_repo_path])
      loader.get_all(sources).each do |source|
        break if @request_shutdown
        source_hosts = source.list_hosts
        hosts << source_hosts

        statsd.gauge('hosts.count', source_hosts.count, :tags => ["source:#{source.class.name}"])
        log.info "read #{source_hosts.count} hosts from source #{source.class.name}"
      end

      hosts.flatten!
      log.info "total of #{hosts.count} entities from #{sources.count} sources"

      return hosts
    end

    def update_alerts(destinations, hosts, alerts, groups, dry_run)
      loader = DestinationsLoader.new([@alerts_repo_path])
      loader.get_all(destinations).each do |dest|
        break if @request_shutdown
        log.info "updating alerts on #{dest.class.name}"
        if dry_run
          dry_run_update_alerts_on_destination(dest, hosts, alerts, groups)
        else
          update_alerts_on_destination(dest, hosts, alerts, groups)
        end
      end
    end

    def dry_run_update_alerts_on_destination(dest, hosts, alerts, groups)
      # track some counters/stats per destination
      start_time = Time.new.to_f

      # get already-defined alerts
      existing_alerts = dest.existing_alerts.dup
      existing_alerts.each{ |key, existing_alert| existing_alert['still_exists'] = false }

      to_remove = existing_alerts.reject{|key, a| !key.start_with?(DRY_RUN_ALERTS_NAME_PREFIX)}

      alerts_queue = build_alerts_queue(hosts, alerts, groups)

      alerts_queue.reject!{|name, pair| !Interferon::need_dry_run(pair[0], existing_alerts)}
      alerts_queue.each do |name, pair|
        alert = pair[0]
        alert.change_name(DRY_RUN_ALERTS_NAME_PREFIX + alert['name'])
      end

      # flush queue
      created_alerts_key_ids = create_alerts(dest, alerts_queue)
      created_alerts_ids = created_alerts_key_ids.map{|a| a[1]}
      to_remove_ids = to_remove.empty? ? [] : to_remove.map{|a| a['id']}
      # remove existing alerts that shouldn't exist
      (created_alerts_ids + to_remove_ids).each do |id|
        break if @request_shutdown
        dest.remove_alert_by_id(id) unless id.nil?
      end

      unless @request_shutdown
        # run time summary
        run_time = Time.new.to_f - start_time
        statsd.histogram('destinations.run_time', run_time, :tags => ["destination:#{dest.class.name}", "dry_run:true"])
        log.info "#{dest.class.name} : dry run completed in %.2f seconds" % (run_time)

        # report destination stats
        dest.report_stats
      end

      if !dest.api_errors.empty?
        raise dest.api_errors.to_s
      end
    end

    def update_alerts_on_destination(dest, hosts, alerts, groups)
      # track some counters/stats per destination
      start_time = Time.new.to_f

      # get already-defined alerts
      existing_alerts = dest.existing_alerts.dup
      existing_alerts.each{ |key, existing_alert| existing_alert['still_exists'] = false }

      alerts_queue = build_alerts_queue(hosts, alerts, groups)

      # flush queue
      created_alerts_keys = create_alerts(dest, alerts_queue).map{|a| a[0]}
      created_alerts_keys.each do |alert_key|
        # don't delete alerts we still have defined
        existing_alerts[alert_key]['still_exists'] = true if existing_alerts.include?(alert_key)
      end

      # remove existing alerts that shouldn't exist
      to_delete = existing_alerts.reject{ |key, existing_alert| existing_alert['still_exists'] }
      to_delete.each do |key, alert|
        break if @request_shutdown
        dest.remove_alert(alert)
      end

      unless @request_shutdown
        # run time summary
        run_time = Time.new.to_f - start_time
        statsd.histogram('destinations.run_time', run_time, :tags => ["destination:#{dest.class.name}", "dry_run:false"])
        log.info "#{dest.class.name} : run completed in %.2f seconds" % (run_time)

        # report destination stats
        dest.report_stats
      end
    end

    def create_alerts(dest, alerts_queue)
      alert_key_ids = []
      alerts_to_create = alerts_queue.keys
      concurrency = dest.concurrency || 10
      unless @request_shutdown
        threads = concurrency.times.map do |i|
          log.info "thread #{i} created"
          t = Thread.new do
            while name = alerts_to_create.shift
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
      # create or update alerts; mark when we've done that
      alerts_queue = Hash.new
      alerts.each do |alert|
        break if @request_shutdown
        counters = {
          :errors => 0,
          :evals => 0,
          :applies => 0,
          :hosts => hosts.length
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
          next if alerts_queue.key?(alert[:name])

          # figure out who to notify
          people = Set.new(alert[:notify][:people])
          alert[:notify][:groups].each do |g|
            people += (groups[g] || [])
          end

          # queue the alert up for creation; we clone the alert to save the current state
          alerts_queue[alert[:name]] ||= [alert.clone, people]
        end

        # log some of the counters
        statsd.gauge('alerts.evaluate.errors', counters[:errors], :tags => ["alert:#{alert}"])
        statsd.gauge('alerts.evaluate.applies', counters[:applies], :tags => ["alert:#{alert}"])

        if counters[:applies] > 0
          log.info "alert #{alert} applies to #{counters[:applies]} of #{counters[:hosts]} hosts"
        end

        # did the alert fail to evaluate on all hosts?
        if counters[:errors] == counters[:hosts]
          log.error "alert #{alert} failed to evaluate in the context of all hosts!"
          log.error "last error on alert #{alert}: #{last_eval_error}"

          statsd.gauge('alerts.evaluate.failed_on_all', 1, :tags => ["alert:#{alert}"])
          log.debug "alert #{alert}: error #{last_eval_error}\n#{last_eval_error.backtrace.join("\n")}"
        else
          statsd.gauge('alerts.evaluate.failed_on_all', 0, :tags => ["alert:#{alert}"])
        end

        # did the alert apply to any hosts?
        if counters[:applies] == 0
          statsd.gauge('alerts.evaluate.never_applies', 1, :tags => ["alert:#{alert}"])
          log.warn "alert #{alert} did not apply to any hosts"
        else
          statsd.gauge('alerts.evaluate.never_applies', 0, :tags => ["alert:#{alert}"])
        end
      end
      alerts_queue
    end

    def self.need_dry_run(alert, existing_alerts)
      existing = existing_alerts[alert['name']]
      if existing.nil?
        true
      else
        !same_alerts_for_dry_run_purpose(alert, existing)
      end
    end

    def self.same_alerts_for_dry_run_purpose(alert_one, alert_two)
      attributes_to_compare = ['silenced', 'silenced_until', 'notify_no_data', 'no_data_timeframe', 'timeout', 'applies']
      attributes_to_compare.each do |key|
        if alert_one[key] != alert_two[key]
          return false
        end
      end
      return alert_one['metric']['datadog_query'] == alert_two['metric']['datadog_query']
    end
  end
end
