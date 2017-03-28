module Interferon
  module MockDSLMixin
    def initialize
    end

    def get_or_set(field, val, block, default)
      @hash ||= Hash.new
      if val.nil?
        f = @hash[field]
        f.nil? ? default : f
      else
        @hash[field] = val
      end
    end
  end

  class MockAlertDSL < AlertDSL
    include MockDSLMixin

    def notify(v = nil)
      get_or_set(:notify, v, nil, nil)
    end

    def metric(v = nil)
      get_or_set(:metric, v, nil, nil)
    end

    def id(v = nil, &block)
      get_or_set(:@id, v, block, '')
    end

    def silenced(v = nil, &block)
      get_or_set(:@silenced, v, block, false)
    end

    def silenced_until(v = nil, &block)
      get_or_set(:@silenced_until, v && Time.parse(v), block, Time.at(0))
    end
  end

  class MockNotifyDSL < NotifyDSL
    include MockDSLMixin
  end

  class MockMetricDSL < MetricDSL
    include MockDSLMixin
  end
end
