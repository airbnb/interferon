require "spec_helper"
require "helpers/loader_helper"

describe 'DynamicLoader' do
  describe 'custom class retrieval' do
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
      expect(test_loader.get_klass('order_test_source')::DIR).to eq('loaders')

      test_loader = TestLoader.new(['./spec/fixtures/loaders2', '/spec/fixtures/loaders'])
      expect(test_loader.get_klass('order_test_source')::DIR).to eq('loaders2')
    end

    it 'eventually looks at all paths' do
      test_loader = TestLoader.new(['./spec/fixtures/loaders', './spec/fixtures/loaders2'])
      expect(test_loader.get_klass('secondary_source')::DIR).to eq('loaders2')
    end
  end

  describe 'standard class retrieval' do
    it 'loads a class from a specified location when possible' do
      loader = Interferon::HostSourcesLoader.new(['./spec/fixtures/loaders'])
      klass = loader.get_klass('test_host_source')

      expect(klass::DIR).to eq('loaders')
    end

    it 'falls back to internal classes' do
      loader = Interferon::HostSourcesLoader.new(['./spec/fixtures/loaders2'])
      klass = loader.get_klass('test_host_source')

      expect(klass::DIR).to eq('interferon')
    end
  end

  describe 'get_all' do
    let(:loader) { TestLoader.new(['./spec/fixtures/loaders2']) }
    before do
      require './spec/fixtures/loaders2/test_sources/test_source'
      require './spec/fixtures/loaders2/test_sources/secondary_source'
    end

    it 'returns an instance for each enabled source' do
      instances = loader.get_all(
        [
          {'type' => 'test_source', 'enabled' => true, 'options' => {}},
          {'type' => 'secondary_source', 'enabled' => true, 'options' => {}},
        ])

      expect(instances.count).to eq(2)
      expect(instances).to contain_exactly(
        an_instance_of(Interferon::TestSources::TestSource),
        an_instance_of(Interferon::TestSources::SecondarySource))
    end

    it 'ignores non-enabled sources' do
      instances = loader.get_all(
        [
          {'type' => 'test_source', 'enabled' => true, 'options' => {}},
          {'type' => 'secondary_source', 'enabled' => false, 'options' => {}},
        ])

      expect(instances.count).to eq(1)
      expect(instances).to contain_exactly(an_instance_of(Interferon::TestSources::TestSource))
    end

    it 'ignores sources with no type set' do
      instances = loader.get_all(
        [
          {'type' => 'test_source', 'enabled' => true, 'options' => {}},
          {'enabled' => true, 'options' => {}},
        ])

      expect(instances.count).to eq(1)
      expect(instances).to contain_exactly(an_instance_of(Interferon::TestSources::TestSource))
    end

    it 'properly sets options on classes it instantiates' do
      instances = loader.get_all(
        [{'type' => 'test_source', 'enabled' => true, 'options' => {'testval' => 5}}])

      expect(instances[0].testval).to eq(5)
    end
  end

end
