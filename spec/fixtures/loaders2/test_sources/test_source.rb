module Interferon::TestSources
  class TestSource
    DIR = 'loaders2'

    attr_accessor :testval
    def initialize(options)
      @testval = options['testval']
    end

  end
end
