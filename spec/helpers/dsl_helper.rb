module Interferon
  module MockDSLMixin
    def initialize
    end

    def get_or_set(field, val, block, default)
      @hash ||= Hash.new
      if val.nil?
        return @hash[field]
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
  end

  class MockNotifyDSL < NotifyDSL
    include MockDSLMixin
  end

  class MockMetricDSL < MetricDSL
    include MockDSLMixin
  end
end
