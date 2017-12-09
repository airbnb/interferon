# frozen_string_literal: true

require 'interferon/version'
require 'interferon/logging'

require 'interferon/loaders'

require 'interferon/alert'
require 'interferon/alert_dsl'
require 'interferon/alert_yaml'

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

    # groups_sources is a hash from type => options for each group source
    # host_sources is a hash from type => options for each host source
    # destinations is a similar hash from type => options for each alerter
    def initialize(config, dry_run = false)
      @alerts_repo_path = config['alerts_repo_path']
      @alert_sources = config['alert_sources']
      @group_sources = config['group_sources'] || {}
      @host_sources = config['host_sources']
      @destinations = config['destinations']
      @processes = config['processes']
      @dry_run = dry_run
      @request_shutdown = false
    end

    def run
      start_time = Time.new.to_f
      Signal.trap('TERM') do
        log.info('SIGTERM received. shutting down gracefully...')
        @request_shutdown = true
      end
      run_desc = @dry_run ? 'dry run' : 'run'
      log.info("beginning alerts #{run_desc}")

      alerts = read_alerts(@alert_sources)
      groups = read_groups(@group_sources)
      hosts = read_hosts(@host_sources)

      @destinations.each do |dest|
        dest['options'] ||= {}
        dest['options']['dry_run'] = true if @dry_run
      end

      update_alerts(@destinations, hosts, alerts, groups)

      run_time = Time.new.to_f - start_time
      if @request_shutdown
        log.info("interferon #{run_desc} shut down by SIGTERM")
      else
        statsd.gauge('run_time', run_time)
        log.info("interferon #{run_desc} complete in %.2f seconds" % run_time)
      end
    end

    def read_alerts(sources)
      alerts = []
      failed = 0
      loader = AlertSourcesLoader.new([@alerts_repo_path])
      loader.get_all(sources).each do |source|
        break if @request_shutdown
        source_results = source.list_alerts
        source_alerts = source_results[:alerts]
        source_failed = source_results[:failed]

        alerts.concat(source_alerts)
        failed += source_failed

        statsd.gauge('alert.read.count', source_alerts.count, tags: ["source:#{source.class.name}"])
        statsd.gauge('alerts.read.failed', source_failed, tags: ["source:#{source.class.name}"])
        log.info("read #{source_alerts.count} alerts from source #{source.class.name}")
      end

      log.info("total of #{alerts.count} alerts from #{sources.count} sources")

      if failed > 0
        if @dry_run
          abort("Failed to read #{failed} alerts")
        else
          log.warn("Failed to read #{failed} alerts")
        end
      end

      alerts
    end

    def read_groups(sources)
      groups = {}
      loader = GroupSourcesLoader.new([@alerts_repo_path])
      loader.get_all(sources).each do |source|
        break if @request_shutdown
        source_groups = source.list_groups { groups }

        # add all people to groups
        people_count = 0
        source_groups.each do |name, people|
          groups[name] ||= []
          groups[name].concat(people)
          people_count += people.count
        end

        log.info(
          "read #{people_count} people in #{source_groups.count} groups " \
          "from source #{source.class.name}"
        )
      end

      log.info(
        "total of #{groups.values.flatten.count} people in #{groups.count} groups " \
        "from #{sources.count} sources"
      )

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
        log.info("read #{source_hosts.count} hosts from source #{source.class.name}")
      end

      hosts.flatten!
      log.info("total of #{hosts.count} entities from #{sources.count} sources")

      hosts
    end

    def update_alerts(destinations, hosts, alerts, groups)
      alerts_queue, alert_errors = build_alerts_queue(hosts, alerts, groups)
      if @dry_run && !alert_errors.empty?
        erroneous_alert_files = alert_errors.map(&:to_s).join(', ')
        raise "Alerts failed to apply or evaluate for all hosts: #{erroneous_alert_files}"
      end

      loader = DestinationsLoader.new([@alerts_repo_path])
      loader.get_all(destinations).each do |dest|
        break if @request_shutdown
        log.info("updating alerts on #{dest.class.name}")
        update_alerts_on_destination(dest, alerts_queue)
      end
    end

    def update_alerts_on_destination(dest, alerts_queue)
      # track some counters/stats per destination
      start_time = Time.new.to_f

      # get already-defined alerts
      existing_alerts = dest.existing_alerts

      run_update(dest, alerts_queue, existing_alerts)

      unless @request_shutdown
        # run time summary
        run_time = Time.new.to_f - start_time
        statsd.histogram(
          @dry_run ? 'destinations.run_time.dry_run' : 'destinations.run_time',
          run_time,
          tags: ["destination:#{dest.class.name}"]
        )
        log.info("#{dest.class.name}: run completed in %.2f seconds" % run_time)

        # report destination stats
        dest.report_stats
      end

      raise dest.api_errors.to_s if @dry_run && !dest.api_errors.empty?
    end

    def run_update(dest, alerts_queue, existing_alerts)
      dest_name = dest.class.name.split('::').last.downcase
      updates_queue = alerts_queue.select do |_name, alert_people_pair|
        alert, _people = alert_people_pair
        dest_name == alert[:target] && dest.need_update(alert_people_pair, existing_alerts)
      end

      # Create alerts in destination
      create_alerts(dest, updates_queue)

      # Existing alerts are pruned until all that remains are
      # alerts that aren't being generated anymore
      to_remove = existing_alerts.dup
      alerts_queue.each do |name, _alert_people_pair|
        old_alert = to_remove[name]

        next if old_alert.nil?
        if old_alert['id'].length == 1
          to_remove.delete(name)
        else
          old_alert['id'] = old_alert['id'].drop(1)
        end
      end

      # Clean up alerts not longer being generated
      to_remove.each do |_name, alert|
        break if @request_shutdown
        dest.remove_alert(alert)
      end
    end

    def create_alerts(dest, alerts_queue)
      alert_keys = []
      alerts_to_create = alerts_queue.keys
      concurrency = dest.concurrency || 10
      unless @request_shutdown
        threads = Array.new(concurrency) do |i|
          log.info("thread #{i} created")
          t = Thread.new do
            while (name = alerts_to_create.shift)
              break if @request_shutdown
              cur_alert, people = alerts_queue[name]
              log.debug("creating alert for #{cur_alert[:name]}")
              alert_keys << dest.create_alert(cur_alert, people)
            end
          end
          t.abort_on_exception = true
          t
        end
        threads.map(&:join)
      end
      alert_keys
    end

    def build_alerts_queue(hosts, alerts, groups)
      alerts_queue = {}
      all_alert_generation_errors = []

      # create or update alerts; mark when we've done that
      result = Parallel.map(alerts, in_processes: @processes) do |alert|
        break if @request_shutdown
        alerts_generated = {}
        alert_generation_errors = []
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
            log.debug("Evaluation of alert #{alert} failed in the context of host #{hostinfo}")
            counters[:errors] += 1
            last_eval_error = e
            next
          end

          # don't define an alert that doesn't apply to this hostinfo
          unless alert[:applies]
            log.debug("alert #{alert[:name]} doesn't apply to #{hostinfo.inspect}")
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
          break if alert[:applies] == :once
        end

        # log some of the counters
        statsd.gauge('alerts.evaluate.errors', counters[:errors], tags: ["alert:#{alert}"])
        statsd.gauge('alerts.evaluate.applies', counters[:applies], tags: ["alert:#{alert}"])

        if counters[:applies] > 0
          log.info("alert #{alert} applies to #{counters[:applies]} of #{counters[:hosts]} hosts")
        end

        # did the alert fail to evaluate on all hosts?
        if counters[:errors] == counters[:hosts] && !last_eval_error.nil?
          log.error("alert #{alert} failed to evaluate in the context of all hosts!")
          log.error("last error on alert #{alert}: #{last_eval_error}")
          statsd.gauge('alerts.evaluate.failed_on_all', 1, tags: ["alert:#{alert}"])
          log.debug(
            "alert #{alert}: " \
            "error #{last_eval_error}\n#{last_eval_error.backtrace.join("\n")}"
          )
          alert_generation_errors << alert
        else
          statsd.gauge('alerts.evaluate.failed_on_all', 0, tags: ["alert:#{alert}"])
        end

        # did the alert apply to any hosts?
        if counters[:applies].zero?
          statsd.gauge('alerts.evaluate.never_applies', 1, tags: ["alert:#{alert}"])
          log.warn("alert #{alert} did not apply to any hosts")
          alert_generation_errors << alert
        else
          statsd.gauge('alerts.evaluate.never_applies', 0, tags: ["alert:#{alert}"])
        end
        [alerts_generated, alert_generation_errors]
      end

      result.each do |generated_alerts, alert_generation_errors|
        alerts_queue.merge!(generated_alerts)
        all_alert_generation_errors += alert_generation_errors
      end
      [alerts_queue, all_alert_generation_errors]
    end
  end
end
