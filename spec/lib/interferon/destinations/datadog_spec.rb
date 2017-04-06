require 'spec_helper'
require 'interferon/destinations/datadog'

describe Interferon::Destinations::Datadog do
  let(:retries) { 3 }
  let(:datadog) {
    Interferon::Destinations::Datadog.new({
      'api_key' => 'TEST_API_KEY',
      'app_key' => 'TEST_APP_KEY',
      'retries' => retries,
    })
  }
  let(:datadog_dry_run) {
    Interferon::Destinations::Datadog.new({
      'api_key' => 'TEST_API_KEY',
      'app_key' => 'TEST_APP_KEY',
      'retries' => retries,
      'dry_run' => true,
    })
  }
  let(:mock_alert_id) { 123 }
  let(:mock_alert) {
    {
      'id' => [mock_alert_id],
      'name' => 'Test Alert',
      'message' => "Test Message",
      'metric' => { 'datadog_query' => 'avg:metric{*}' },
      'silenced' => {},
    }
  }
  let(:mock_people) { ['foo', 'bar', 'baz'] }

  describe ".get_existing_alerts" do
    it "calls dogapi get_all_monitors" do
      expect_any_instance_of(Dogapi::Client).to receive(:get_all_monitors).and_return([200, ""])
      datadog.get_existing_alerts
    end
  end

  describe ".existing_alerts" do
    it "retries dogapi get_all_monitors" do
      return_vals = [[400, ""]] * (retries + 1)
      expect_any_instance_of(Dogapi::Client).to receive(:get_all_monitors).and_return(*return_vals)
      expect { datadog.existing_alerts }.to raise_error RuntimeError
    end
  end

  describe ".create_alert" do
    it "calls dogapi monitor" do
      expect_any_instance_of(Dogapi::Client).to receive(:monitor).and_return([200, ""])
      expect(datadog).to receive(:existing_alerts).and_return({})
      datadog.create_alert(mock_alert, mock_people)
    end

    it "calls dogapi update_monitor when alert name is found" do
      expect_any_instance_of(Dogapi::Client).to receive(:update_monitor).and_return([200, ""])
      expect(datadog).to receive(:existing_alerts).and_return(
        {
          "Test Alert" => {
            "id" => 567,
            "name" => 'Test Alert',
            "options" => {
              "silenced" => {}
            }
          }
        }
      )
      datadog.create_alert(mock_alert, mock_people)
    end

    it "calls dogapi to delete and recreate when alert name is found" do
      expect_any_instance_of(Dogapi::Client).to receive(:delete_monitor).and_return([200, ""])
      expect_any_instance_of(Dogapi::Client).to receive(:monitor).and_return([200, ""])
      expect(datadog).to receive(:existing_alerts).and_return(
        {
          "Test Alert" => {
            "id" => 567,
            "type" => "event alert",
            "name" => 'Test Alert',
            "options" => {
              "silenced" => {}
            }
          }
        }
      )
      datadog.create_alert(mock_alert, mock_people)
    end

    it "calls dogapi to unmute when exiting alert is muted" do
      expect_any_instance_of(Dogapi::Client).to receive(:update_monitor).and_return([200, ""])
      expect_any_instance_of(Dogapi::Client).to receive(:unmute_monitor).and_return([200, ""])
      expect(datadog).to receive(:existing_alerts).and_return(
        {
          "Test Alert" => {
            "id" => 567,
            "name" => 'Test Alert',
            "options" => {
              "silenced" => { '*' => nil }
            }
          }
        }
      )
      datadog.create_alert(mock_alert, mock_people)
    end

    it "always calls monitor in dry-run" do
      expect_any_instance_of(Dogapi::Client).to receive(:monitor).and_return([200, ""])
      expect(datadog_dry_run).to receive(:existing_alerts).and_return(
        {
          "Test Alert" => {
            "id" => 567,
            "name" => 'Test Alert',
          }
        }
      )
      datadog_dry_run.create_alert(mock_alert, mock_people)
    end
  end

  describe ".remove_alert" do
    it "calls dogapi delete_monitor with the correct alert id" do
      mock_alert["message"] += Interferon::Destinations::Datadog::ALERT_KEY
      expect_any_instance_of(Dogapi::Client).to receive(:delete_monitor).
        with(mock_alert_id).and_return([200, ""])
      datadog.remove_alert(mock_alert)
    end

    it "does not call dogapi delete_monitor in dry_run" do
      mock_alert["message"] += Interferon::Destinations::Datadog::ALERT_KEY
      expect_any_instance_of(Dogapi::Client).to_not receive(:delete_monitor)
      datadog_dry_run.remove_alert(mock_alert)
    end

    it "does not call dogapi delete_monitor when ALERT_KEY is missing" do
      expect_any_instance_of(Dogapi::Client).to_not receive(:delete_monitor)
      datadog.remove_alert(mock_alert)
    end

  end

  describe ".remove_alert_by_id" do
    it "calls dogapi delete_monitor" do
      expect_any_instance_of(Dogapi::Client).to receive(:delete_monitor).
        with(mock_alert_id).and_return([200, ""])
      datadog.remove_alert_by_id(mock_alert_id)
    end
  end
end
