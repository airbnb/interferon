
module Interferon
  module DSLMixin
    def initialize(hostinfo)
      @hostinfo = hostinfo
    end

    def method_missing(meth, *args, &block)
      raise ArgumentError, "No such alerts field '#{meth}'"
    end

    def [](arg)
      self.send(arg)
    end

    private
    def get_or_set(field, val, block, default)
      if val.nil? && block.nil?
        f = instance_variable_get(field)
        f.nil? ? default : f
      elsif val.nil?
        instance_variable_set(field, block.call)
      elsif block.nil?
        instance_variable_set(field, val)
      else
        raise ArgumentError, "You must pass either a value or a block but not both to #{field}"
      end
    end
  end

  class AlertDSL
    include DSLMixin

    def name(v = nil, &block)
      get_or_set(:@name, v, block, '')
    end

    def message(v = nil, &block)
      get_or_set(:@message, v, block, '')
    end

    def silenced(v = nil, &block)
      get_or_set(:@silenced, v, block, false)
    end

    def silenced_until(v = nil, &block)
      get_or_set(:@silenced_until, v && Time.parse(v), block, Time.at(0))
    end

    def notify_no_data(v = nil, &block)
      get_or_set(:@notify_no_data, v, block, false)
    end

    def no_data_timeframe(v = nil, &block)
      get_or_set(:@no_data_timeframe, v, block, false)
    end

    def timeout(v = nil, &block)
      get_or_set(:@timeout, v, block, false)
    end

    def applies(v = nil, &block)
      get_or_set(:@applies, v, block, false)
    end

    def notify(v = nil)
      @notify ||= NotifyDSL.new(@hostinfo)
    end

    def metric(v = nil)
      @metric ||= MetricDSL.new(@hostinfo)
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
  end

  class MetricDSL
    include DSLMixin

    def datadog_query(v = nil, &block)
      get_or_set(:@datadog_query, v, block, '')
    end
  end
end
