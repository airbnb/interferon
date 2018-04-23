# frozen_string_literal: true

require 'spec_helper'
require 'interferon/alert_sources/filesystem'

describe Interferon::AlertSources::Filesystem do
  describe '#initialize' do
    before do
      @options = []
    end

    it 'requires alert_types as an option' do
      expect { described_class.new }.to raise_error(ArgumentError)
    end

    it 'requires path in alert_types as an option' do
      alert_types = [{ 'extension' => '', 'class' => '' }]
      @options = { 'alert_types' => alert_types }
      expect { described_class.new(@options) }.to raise_error(ArgumentError)
    end

    it 'set default extension in alert_types' do
      alert_types = [{ 'path' => '', 'class' => '' }]
      @options = { 'alert_types' => alert_types }
      set_alert_types = described_class.new(@options).instance_variable_get(:@alert_types)
      expect(set_alert_types[0]['extension']).to eq('*.rb')
    end

    it 'sets default class in alert_types' do
      alert_types = [{ 'path' => '', 'extension' => '' }]
      @options = { 'alert_types' => alert_types }
      set_alert_types = described_class.new(@options).instance_variable_get(:@alert_types)
      expect(set_alert_types[0]['class']).to eq('Alert')
    end

    it 'sets alert_types' do
      alert_types = [{ 'path' => '', 'extension' => '', 'class' => '' }]
      @options = { 'alert_types' => alert_types }
      expect(described_class.new(@options).instance_variable_get(:@alert_types)).to eq(alert_types)
    end
  end

  describe '#list_alerts' do
    context 'with no types' do
      let(:fs_source) { described_class.new('alert_types' => []) }

      it 'returns an empty list of alerts and zero failed' do
        expect(fs_source.list_alerts).to eq(alerts: [], failed: 0)
      end
    end

    context 'with one type (Alert)' do
      let(:fs_source) do
        described_class.new(
          'alert_types' => [{ 'path' => 'alerts', 'extension' => '*.rb', 'class' => 'Alert' }]
        )
      end

      before do
        allow(Dir).to receive(:exist?).and_return(true)
      end

      it 'returns an empty list of alerts and zero failed' do
        expect(fs_source.list_alerts).to eq(alerts: [], failed: 0)
      end

      it 'creates an Alert with the alert file' do
        mock_alert = double('alert')
        allow(Dir).to receive(:glob).and_return(['somefile.rb'])
        expect(Interferon::Alert).to receive(:new).and_return(mock_alert)
        expect(fs_source.list_alerts).to eq(alerts: [mock_alert], failed: 0)
      end

      it 'increments failed on bad alert' do
        allow(Dir).to receive(:glob).and_return(['somefile.rb'])
        expect(Interferon::Alert).to receive(:new).and_raise(StandardError)
        expect(fs_source.list_alerts).to eq(alerts: [], failed: 1)
      end
    end

    context 'with multiple types' do
      let(:fs_source) do
        described_class.new(
          'alert_types' => [
            { 'path' => 'alerts', 'extension' => '*.rb', 'class' => 'Alert' },
            { 'path' => 'alert_definitions', 'extension' => '*.yml', 'class' => 'AlertYaml' },
          ]
        )
      end

      before do
        allow(Dir).to receive(:exist?).and_return(true)
      end

      it 'returns an empty list of alerts and zero failed' do
        expect(fs_source.list_alerts).to eq(alerts: [], failed: 0)
      end

      it 'creates an Alert and AlertYaml when defined' do
        mock_alert = double('alert')
        mock_alert_yaml = double('alert_yaml')
        allow(Dir).to receive(:glob).twice.and_return(['somefile.rb'], ['another_file.yml'])
        expect(Interferon::Alert).to receive(:new).and_return(mock_alert)
        expect(Interferon::AlertYaml).to receive(:new).and_return(mock_alert_yaml)
        expect(fs_source.list_alerts).to eq(alerts: [mock_alert, mock_alert_yaml], failed: 0)
      end

      it 'increments failed on bad alert' do
        allow(Dir).to receive(:glob).and_return(['somefile.rb'], ['another_file.yml'])
        expect(Interferon::Alert).to receive(:new).and_raise(StandardError)
        expect(Interferon::Alert).to receive(:new).and_raise(StandardError)
        expect(fs_source.list_alerts).to eq(alerts: [], failed: 2)
      end
    end
  end
end
