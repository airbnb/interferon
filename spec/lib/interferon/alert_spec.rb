require "spec_helper"

describe '.get_name_from_path' do
  subject { Interferon::Alert }
  let(:alerts_repo_path) { '/the/path/to' }
  let(:base_dir_alert) { '/the/path/to/alerts/alert.rb'}
  let(:sub_dir_alert) { '/the/path/to/alerts/x/y/alert.rb'}

  it 'only returns the filename for alerts directly under the alerts folder' do
    expect(subject.get_name_from_path(alerts_repo_path, base_dir_alert)).to eq('alert.rb')
  end

  it 'returns the relative path for alerts in a subdirectory under the alerts folder' do
    expect(subject.get_name_from_path(alerts_repo_path, sub_dir_alert)).to eq('x/y/alert.rb')
  end
end
