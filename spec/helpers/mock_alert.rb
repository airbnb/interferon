module Interferon
  class MockAlert < Alert
    def initialize(dsl)
      @filename = 'MOCKALERT'
      @dsl = dsl
    end

    def []=(key, val)
      @dsl.get_or_set(('@' + key).to_sym, val, nil, nil)
    end
  end
end
