# frozen_string_literal: true

require 'spec_helper'
require 'helpers/optica_helper'
require 'interferon/host_sources/optica'

describe Interferon::HostSources::Optica do
  let(:optica) { Interferon::HostSources::Optica.new('host' => '127.0.0.1') }

  describe '.list_hosts' do
    before do
      expect(optica).to receive(:optica_data).and_return(OpticaHelper.example_output)
    end

    let(:list) { optica.list_hosts }

    it 'returns all of the hosts that optica provides' do
      expect(list.length).to eq(OpticaHelper.example_nodes.length)
    end

    it 'includes all required attributes with each hostinfo' do
      list.each do |host|
        expect(host).to include(:source, :hostname, :role, :environment, :owners, :owner_groups)
      end
    end

    it 'does not barf if ownership info is missing' do
      expect(list).to satisfy do |l|
        l.one? do |h|
          h[:owners].empty? && h[:owner_groups].empty?
        end
      end
    end
  end
end
