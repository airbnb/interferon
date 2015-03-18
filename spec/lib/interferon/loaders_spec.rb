require "spec_helper"

describe 'DynamicLoader' do
  describe 'custom class retrieval' do
    before do
      # define the module we're working in
      module ::Interferon::TestSources; end

      # define a test loader we'll be using
      class TestLoader < Interferon::DynamicLoader
        def initialize_attributes
          @loader_for = 'test fixtures'
          @type_path = 'test_sources'
          @module = ::Interferon::TestSources
        end
      end
    end

    it 'properly loads a custom test source of given type' do
      test_loader = TestLoader.new(['./spec/fixtures/loaders'])
      expect(test_loader.get_klass('test_source')).to be_a(Class)
    end

    it 'throws an ArgumentError when the type cannot be found' do
      test_loader = TestLoader.new(['./spec/fixtures/loaders'])
      expect{test_loader.get_klass('unknown_source')}.to raise_error(ArgumentError)
    end

    it 'looks at custom paths in order' do
      test_loader = TestLoader.new(['./spec/fixtures/loaders', '/spec/fixtures/loaders2'])
      expect(test_loader.get_klass('test_source')::DIR).to eq('loaders')

      test_loader = TestLoader.new(['./spec/fixtures/loaders2', '/spec/fixtures/loaders'])
      expect(test_loader.get_klass('test_source')::DIR).to eq('loaders2')
    end

    it 'eventually looks at all paths' do
      test_loader = TestLoader.new(['./spec/fixtures/loaders', './spec/fixtures/loaders2'])
      expect(test_loader.get_klass('secondary_source')::DIR).to eq('loaders2')
    end
  end

  describe 'standard class retrieval' do
    it 'loads a class from a specified location when possible' do
      loader = Interferon::HostSourcesLoader.new(['./spec/fixtures/loaders'])
      klass = loader.get_klass('optica')

      expect(klass::DIR).to eq('loaders')
    end

    it 'falls back to internal classes' do
      loader = Interferon::HostSourcesLoader.new(['./spec/fixtures/loaders2'])
      klass = loader.get_klass('optica')

      expect(klass::DIR).to eq('interferon')
    end
  end

end
