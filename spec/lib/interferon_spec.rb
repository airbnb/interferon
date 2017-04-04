require 'spec_helper'
require 'helpers/mock_alert'
require 'helpers/dsl_helper'
require 'interferon/destinations/datadog'

include Interferon

describe Interferon::Interferon do

  let(:the_existing_alerts) {mock_existing_alerts}
  let(:dest) {MockDest.new(the_existing_alerts)}

  context "when checking alerts have changed" do
    it "detects a change if alert message is different" do
      alert1 = create_test_alert('name1', 'testquery', 'message1')
      alert2 = mock_alert_json('name2', 'testquery', 'message2')

      expect(Interferon::Interferon.same_alerts(dest, [alert1, []], alert2)).to be false
    end

    it "detects a change if datadog query is different" do
      alert1 = create_test_alert('name1', 'testquery1', 'message1')
      alert2 = mock_alert_json('name2', 'testquery2', 'message2')

      expect(Interferon::Interferon.same_alerts(dest, [alert1, []], alert2)).to be false
    end

    it "detects a change if alert notify_no_data is different" do
      alert1 = create_test_alert('name1', 'testquery1', 'message1', false)
      alert2 = mock_alert_json('name2', 'testquery2', 'message2', true)

      expect(Interferon::Interferon.same_alerts(dest, [alert1, []], alert2)).to be false
    end

    it "detects a change if alert silenced is different" do
      alert1 = create_test_alert('name1', 'testquery1', 'message1', false, true)
      alert2 = mock_alert_json('name2', 'testquery2', 'message2', false, false)

      expect(Interferon::Interferon.same_alerts(dest, [alert1, []], alert2)).to be false
    end

    it "does not detect a change when alert datadog query and message are the same" do
      alert1 = create_test_alert('name1', 'testquery1', 'message1')
      alert2 = mock_alert_json('name1', 'testquery1', "message1\nRegards, [Robo Ops](https://instructure.atlassian.net/wiki/display/IOPS/Monitors).")

      expect(Interferon::Interferon.same_alerts(dest, [alert1, []], alert2)).to be true
    end
  end

  context "dry_run_update_alerts_on_destination" do
    let(:interferon) {Interferon::Interferon.new(nil,nil,nil,nil,true,0)}

    before do
      allow_any_instance_of(MockAlert).to receive(:evaluate)
      allow(dest).to receive(:remove_alert)
      allow(dest).to receive(:remove_alert_by_id)
      allow(dest).to receive(:report_stats)
    end

    it 'does not re-run existing alerts' do
      alerts = mock_existing_alerts
      expect(dest).not_to receive(:create_alert)
      expect(dest).not_to receive(:remove_alert_by_id)

      interferon.update_alerts_on_destination(dest, ['host'], [alerts['name1'], alerts['name2']], {})
    end

    it 'runs added alerts' do
      alerts = mock_existing_alerts
      added = create_test_alert('name3', 'testquery3', '')
      expect(dest).to receive(:create_alert).once.and_call_original
      expect(dest).to receive(:remove_alert_by_id).with('3').once

      interferon.update_alerts_on_destination(dest, ['host'], [alerts['name1'], alerts['name2'], added], {})
    end

    it 'runs updated alerts' do
      added = create_test_alert('name1', 'testquery3', '')
      expect(dest).to receive(:create_alert).once.and_call_original
      expect(dest).to receive(:remove_alert_by_id).with('1').once

      interferon.update_alerts_on_destination(dest, ['host'], [added], {})
    end

    it 'deletes old alerts' do
      expect(dest).to receive(:remove_alert).twice

      interferon.update_alerts_on_destination(dest, ['host'], [], {})
    end

    it 'deletes duplicate old alerts' do
      alert1 = mock_alert_json('name1', 'testquery1', '', false, false, [1, 2, 3])
      alert2 = mock_alert_json('name2', 'testquery2', '')
      existing_alerts = {'name1' => alert1, 'name2' => alert2}
      dest = MockDest.new(existing_alerts)
      allow(dest).to receive(:remove_alert)
      allow(dest).to receive(:remove_alert_by_id)
      allow(dest).to receive(:report_stats)

      expect(dest).to receive(:remove_alert).with(existing_alerts['name1'])
      expect(dest).to receive(:remove_alert).with(existing_alerts['name2'])

      interferon.update_alerts_on_destination(dest, ['host'], [], {})
    end

    it 'deletes duplicate old alerts when creating new alert' do
      alert1 = mock_alert_json('name1', 'testquery1', '', false, false, [1, 2, 3])
      alert2 = mock_alert_json('name2', 'testquery2', '')
      existing_alerts = {'name1' => alert1, 'name2' => alert2}
      dest = MockDest.new(existing_alerts)
      allow(dest).to receive(:remove_alert)
      allow(dest).to receive(:remove_alert_by_id)
      allow(dest).to receive(:report_stats)

      added = create_test_alert('name1', 'testquery1', '')

      # Since we change id to nil we will not be attempting to delete duplicate alerts
      # during dry run
      # expect(dest).to receive(:remove_alert).with(existing_alerts['name1'])
      expect(dest).to receive(:remove_alert).with(existing_alerts['name2'])

      interferon.update_alerts_on_destination(dest, ['host'], [added], {})
    end
  end

  context "update_alerts_on_destination" do
    let(:interferon) {Interferon::Interferon.new(nil,nil,nil,nil,false,0)}

    before do
      allow_any_instance_of(MockAlert).to receive(:evaluate)
      allow(dest).to receive(:remove_alert)
      allow(dest).to receive(:remove_alert_by_id)
      allow(dest).to receive(:report_stats)
    end

    it 'does not re-run existing alerts' do
      alerts = mock_existing_alerts
      expect(dest).not_to receive(:create_alert)
      expect(dest).not_to receive(:remove_alert_by_id)

      interferon.update_alerts_on_destination(dest, ['host'], [alerts['name1'], alerts['name2']], {})
    end

    it 'runs added alerts' do
      alerts = mock_existing_alerts
      added = create_test_alert('name3', 'testquery3', '')
      expect(dest).to receive(:create_alert).once.and_call_original
      expect(dest).not_to receive(:remove_alert_by_id).with('3')

      interferon.update_alerts_on_destination(dest, ['host'], [alerts['name1'], alerts['name2'], added], {})
    end

    it 'runs updated alerts' do
      added = create_test_alert('name1', 'testquery3', '')
      expect(dest).to receive(:create_alert).once.and_call_original
      expect(dest).not_to receive(:remove_alert_by_id).with('1')

      interferon.update_alerts_on_destination(dest, ['host'], [added], {})
    end

    it 'deletes old alerts' do
      alerts = mock_existing_alerts
      expect(dest).to receive(:remove_alert).with(alerts['name1'])
      expect(dest).to receive(:remove_alert).with(alerts['name2'])

      interferon.update_alerts_on_destination(dest, ['host'], [], {})
    end

    it 'deletes duplicate old alerts' do
      alert1 = mock_alert_json('name1', 'testquery1', '', false, false, [1, 2, 3])
      alert2 = mock_alert_json('name2', 'testquery2', '')
      existing_alerts = {'name1' => alert1, 'name2' => alert2}
      dest = MockDest.new(existing_alerts)
      allow(dest).to receive(:remove_alert)
      allow(dest).to receive(:remove_alert_by_id)
      allow(dest).to receive(:report_stats)

      expect(dest).to receive(:remove_alert).with(existing_alerts['name1'])
      expect(dest).to receive(:remove_alert).with(existing_alerts['name2'])

      interferon.update_alerts_on_destination(dest, ['host'], [], {})
    end

    it 'deletes duplicate old alerts when creating new alert' do
      alert1 = mock_alert_json('name1', 'testquery1', '', false, false, [1, 2, 3])
      alert2 = mock_alert_json('name2', 'testquery2', '')
      existing_alerts = {'name1' => alert1, 'name2' => alert2}
      dest = MockDest.new(existing_alerts)
      allow(dest).to receive(:report_stats)

      added = create_test_alert('name1', 'testquery1', '')

      expect(dest).to receive(:remove_alert).with(mock_alert_json('name1', 'testquery1', '', false, false, [2, 3]))
      expect(dest).to receive(:remove_alert).with(existing_alerts['name2'])

      interferon.update_alerts_on_destination(dest, ['host'], [added], {})
    end
  end

  def mock_existing_alerts
    alert1 = mock_alert_json('name1', 'testquery1', '')
    alert2 = mock_alert_json('name2', 'testquery2', '')
    {'name1' => alert1, 'name2' => alert2}
  end

  class MockDest < Interferon::Destinations::Datadog
    @existing_alerts

    def initialize(the_existing_alerts)
      @existing_alerts = the_existing_alerts
    end

    def create_alert(alert, people)
      name = alert['name']
      id = [alert['name'][-1]]
      [name, id]
    end

    def existing_alerts
      @existing_alerts
    end
  end

  def mock_alert_json(name, datadog_query, message, notify_no_data=false, silenced=false, id=nil)
    { 'name'=> name,
      'query'=> datadog_query,
      'message'=> message,
      'notify_no_data' => notify_no_data,
      'silenced' => silenced,
      'id' => id.nil? ? [name[-1]] : id
    }
  end

  def create_test_alert(name, datadog_query, message, notify_no_data=false, silenced=false)
    alert_dsl = MockAlertDSL.new
    metric_dsl = MockMetricDSL.new
    metric_dsl.datadog_query(datadog_query)
    alert_dsl.metric(metric_dsl)
    alert_dsl.name(name)
    alert_dsl.applies(true)
    alert_dsl.message(message)
    alert_dsl.silenced(silenced)
    alert_dsl.notify_no_data(notify_no_data)
    notify_dsl = MockNotifyDSL.new
    notify_dsl.groups(['a'])
    alert_dsl.notify(notify_dsl)
    MockAlert.new(alert_dsl)
  end
end
