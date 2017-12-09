require 'spec_helper'
require 'interferon/alert'

describe Interferon::Alert do
  let(:sample_alert_repo_path) { './spec/fixtures/files/' }
  let(:sample_alert_path) { File.join(sample_alert_repo_path, 'sample_alert.rb') }

  describe '#initialize' do
    it 'reads a file' do
      expect(File).to receive(:read).with(sample_alert_path)
      Interferon::Alert.new(sample_alert_repo_path, sample_alert_path)
    end
  end

  describe '#to_s' do
    it 'returns filename as the alert path without the repo' do
      allow(File).to receive(:read).with(sample_alert_path)
      alert = Interferon::Alert.new(sample_alert_repo_path, sample_alert_path)
      expect(alert.to_s).to eq('sample_alert.rb')
    end

    it 'returns filename as the nested alert path without the repo' do
      nested_alert_path = File.join(sample_alert_repo_path, '/a/b/c/sample_alert.rb')
      allow(File).to receive(:read).with(nested_alert_path)
      alert = Interferon::Alert.new(sample_alert_repo_path, nested_alert_path)
      expect(alert.to_s).to eq('a/b/c/sample_alert.rb')
    end
  end

  describe '#evaluate' do
    it 'applies suffix to name' do
      suffix = 'suffix string'
      allow(File).to receive(:read).with(sample_alert_path).and_return('name \'foo\'')
      alert = Interferon::Alert.new(sample_alert_repo_path, sample_alert_path, suffix: suffix)
      alert.evaluate({})
      expect(alert['name']).to include(suffix)
    end
  end
end
