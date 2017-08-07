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
    def initialize(config, dry_run = false, processes = nil)
      @alerts_repo_path = config['alerts_repo_path']
      @group_sources = config['group_sources'] || {}
      @host_sources = config['host_sources']
      @destinations = config['destinations']
      @alerts_repo_type = config['alerts_repo_type']
      @alerts_repo_last_modified = config['alerts_repo_last_modified']
      @dry_run = dry_run
      @processes = processes
      @evaluation_errors = []
      @request_shutdown = false
    end

    def run
      Signal.trap('TERM') do
        log.info('SIGTERM received. shutting down gracefully...')
        @request_shutdown = true
      end
      run_desc = @dry_run ? 'dry run' : 'run'
      log.info("beginning alerts #{run_desc}")

      alerts = read_alerts
      groups = read_groups(@group_sources)
      hosts = read_hosts(@host_sources)

      @destinations.each do |dest|
        dest['options'] ||= {}
        dest['options']['dry_run'] = true if @dry_run
      end

      update_alerts(@destinations, hosts, alerts, groups)

      if @request_shutdown
        log.info("interferon #{run_desc} shut down by SIGTERM")
      else
        log.info("interferon #{run_desc} complete")
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
          log.warn("error reading alert file #{alert_file}: #{e}")
          failed += 1
        else
          alerts << alert
        end
      end

      log.info("read #{alerts.count} alerts files from #{path}")

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
      alerts_queue, error_count = build_alerts_queue(hosts, alerts, groups)
      raise 'Some alerts failed to apply or evaluate for all hosts' if @dry_run && error_count > 0

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
        log.info("#{dest.class.name} : run completed in %.2f seconds" % run_time)

        # report destination stats
        dest.report_stats
      end

      raise dest.api_errors.to_s if @dry_run && !dest.api_errors.empty?
    end

    def run_update(dest, alerts_queue, existing_alerts)
      updates_queue = alerts_queue.reject do |_name, alert_people_pair|
        !dest.need_update(alert_people_pair, existing_alerts)
      end

      # Create alerts in destination
      create_alerts(dest, updates_queue)

      # Do not continue to remove alerts during dry-run
      return if @dry_run

      # Existing alerts are pruned until all that remains are
      # alerts that aren't being generated anymore
      to_remove = existing_alerts.dup
      alerts_queue.each do |_name, alert_people_pair|
        alert, _people = alert_people_pair
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
          log.info("thread #{i} created")
          t = Thread.new do
            while (name = alerts_to_create.shift)
              break if @request_shutdown
              cur_alert, people = alerts_queue[name]
              log.debug("creating alert for #{cur_alert[:name]}")
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
      errors_count = 0

      # create or update alerts; mark when we've done that
      result = Parallel.map(alerts, in_processes: @processes) do |alert|
        break if @request_shutdown
        alerts_generated = {}
        alert_generation_error_count = 0
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
          alert_generation_error_count += 1
        else
          statsd.gauge('alerts.evaluate.failed_on_all', 0, tags: ["alert:#{alert}"])
        end

        # did the alert apply to any hosts?
        if counters[:applies] == 0
          statsd.gauge('alerts.evaluate.never_applies', 1, tags: ["alert:#{alert}"])
          log.warn("alert #{alert} did not apply to any hosts")
          alert_generation_error_count += 1
        else
          statsd.gauge('alerts.evaluate.never_applies', 0, tags: ["alert:#{alert}"])
        end
        [alerts_generated, alert_generation_error_count]
      end

      result.each do |generated_alerts, alert_generation_error_count|
        alerts_queue.merge!(generated_alerts)
        errors_count += alert_generation_error_count
      end
      [alerts_queue, errors_count]
    end
  end
end
