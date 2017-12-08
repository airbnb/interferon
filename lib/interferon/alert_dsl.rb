# frozen_string_literal: true

require 'interferon/work_hours_helper'

module Interferon
  module DSLMixin
    def initialize(hostinfo)
      @hostinfo = hostinfo
    end

    def method_missing(meth, *_args)
      raise ArgumentError, "No such alerts field '#{meth}'"
    end

    def [](arg)
      send(arg)
    end

    private

    def get_or_set(field, val, block, default)
      if val.nil? && block.nil?
        f = instance_variable_get(field)
        f.nil? ? default : f
      elsif !val.nil? && !block.nil?
        raise ArgumentError, "You must pass either a value or a block but not both to #{field}"
      else
        f = val.nil? ? block.call : val
        f = yield(f) if block_given?
        instance_variable_set(field, f)
      end
    end
  end

  class AlertDSL
    include DSLMixin

    def locked(v = nil, &block)
      get_or_set(:@locked, v, block, false)
    end

    def name(v = nil, &block)
      get_or_set(:@name, v, block, '', &:strip)
    end

    def message(v = nil, &block)
      get_or_set(:@message, v, block, '')
    end

    def monitor_type(v = nil, &block)
      get_or_set(:@monitor_type, v, block, 'metric alert')
    end

    def applies(v = nil, &block)
      get_or_set(:@applies, v, block, false)
    end

    def silenced(v = nil, &block)
      get_or_set(:@silenced, v, block, {}) do |val|
        if val.is_a? Hash
          val
        elsif val == true
          { '*' => nil }
        else
          {}
        end
      end
    end

    def is_work_hour?(args = {})
      # Args can contain
      # :hours => range of work hours (0 to 23h), for example (9..16)
      # :days => range of week days (0 = sunday), for example (1..5) (Monday to Friday)
      # :timezone => example 'America/Los_Angeles'
      # 9 to 5 Monday to Friday in PST is the default
      WorkHoursHelper.is_work_hour?(Time.now.utc, args)
    end

    def notify_no_data(v = nil, &block)
      get_or_set(:@notify_no_data, v, block, false)
    end

    def no_data_timeframe(v = nil, &block)
      get_or_set(:@no_data_timeframe, v, block, nil)
    end

    def timeout(v = nil, &block)
      get_or_set(:@timeout, v, block, nil)
    end

    def timeout_h
      # timeout is in seconds, but set it to 1 hour at least
      timeout ? [1, timeout.to_i / 3600].max : nil
    end

    def thresholds(v = nil, &block)
      get_or_set(:@thresholds, v, block, nil)
    end

    def evaluation_delay(v = nil, &block)
      get_or_set(:@evaluation_delay, v, block, nil)
    end

    def new_host_delay(v = nil, &block)
      get_or_set(:@new_host_delay, v, block, 300)
    end

    def require_full_window(v = nil, &block)
      get_or_set(:@require_full_window, v, block, nil)
    end

    def notify(_v = nil)
      @notify ||= NotifyDSL.new(@hostinfo)
    end

    def metric(_v = nil)
      @metric ||= MetricDSL.new(@hostinfo)
    end

    def target(v = nil, &block)
      get_or_set(:@target, v, block, 'datadog')
    end
  end

  class NotifyDSL
    include DSLMixin

    def people(v = nil, &block)
      get_or_set(:@people, v, block, [])
    end

    def groups(v = nil, &block)
      get_or_set(:@groups, v, block, [])
    end

    def fallback_groups(v=nil, &block)
      get_or_set(:@fallback_groups, v, block, [])
    end

    def audit(v = nil, &block)
      get_or_set(:@audit, v, block, false)
    end

    def recovery(v = nil, &block)
      get_or_set(:@recovery, v, block, true)
    end

    def include_tags(v = nil, &block)
      get_or_set(:@include_tags, v, block, nil)
    end
  end

  class MetricDSL
    include DSLMixin

    def datadog_query(v = nil, &block)
      get_or_set(:@datadog_query, v, block, '', &:strip)
    end
  end
end
