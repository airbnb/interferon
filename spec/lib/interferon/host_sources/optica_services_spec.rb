require 'spec_helper'
require 'helpers/optica_helper'
require 'interferon/host_sources/optica_services'

describe Interferon::HostSources::OpticaServices do
  let(:optica_services) { Interferon::HostSources::OpticaServices.new('host' => '127.0.0.1') }

  describe '.list_hosts' do
    before do
      expect(optica_services).to receive(:optica_data).and_return(OpticaHelper.example_output)
    end

    let(:list) { optica_services.list_hosts }
    let(:service1) { list.select { |s| s[:service] == 'service1' }[0] }
    let(:service2) { list.select { |s| s[:service] == 'service2' }[0] }

    it 'returns both of the services we know about' do
      expect(list.length).to eq(2)
    end

    it 'includes all required attributes with each hostinfo' do
      list.each do |service|
        expect(service).to include(
          :source,
          :service,
          :owners,
          :owner_groups,
          :consumer_roles,
          :consumer_machine_count,
          :provider_machine_count
        )
      end
    end

    it 'does not barf if ownership info is missing' do
      expect(service2[:owners]).to be_empty
      expect(service2[:owner_groups]).to be_empty
    end

    it 'knows that box1 is using both of the services' do
      expect(list).to satisfy do |l|
        l.all? do |s|
          s[:consumer_machine_count] == 1 && s[:consumer_roles] == ['role1']
        end
      end
    end

    it 'knows that service1 is provided by two machines' do
      expect(service1[:provider_machine_count]).to eq(2)
    end

    it 'merges the ownership for all machines that provide service1' do
      all_owners = OpticaHelper.example_node_2['ownership']['people'] +
                   OpticaHelper.example_node_4['ownership']['people']
      all_owner_groups = OpticaHelper.example_node_2['ownership']['groups'] +
                         OpticaHelper.example_node_4['ownership']['groups']

      expect(service1[:owners]).to contain_exactly(*all_owners)
      expect(service1[:owner_groups]).to contain_exactly(*all_owner_groups)
    end
  end
end
