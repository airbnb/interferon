require 'spec_helper'
require 'helpers/mock_alert'
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
      alert1 = create_test_alert('name1', 'testquery1', 'message1', { :notify_no_data => false })
      alert2 = mock_alert_json(
        'name2',
        'testquery2',
        'message2',
        nil,
        [1],
        { :notify_no_data => true }
      )

      expect(Interferon::Interferon.same_alerts(dest, [alert1, []], alert2)).to be false
    end

    it "detects a change if alert silenced is different" do
      alert1 = create_test_alert('name1', 'testquery1', 'message1', { :silenced => true })
      alert2 = mock_alert_json('name2', 'testquery2', 'message2', nil, [1], { :silenced => {} })

      expect(Interferon::Interferon.same_alerts(dest, [alert1, []], alert2)).to be false
    end

    it "does not detect a change when alert datadog query and message are the same" do
      alert1 = create_test_alert('name1', 'testquery1', 'message1')
      alert2 = mock_alert_json(
        'name1',
        'testquery1',
        "message1\nRegards, [Robo Ops](https://instructure.atlassian.net/wiki/display/IOPS/Monitors)."
      )

      expect(Interferon::Interferon.same_alerts(dest, [alert1, []], alert2)).to be true
    end
  end

  context "#build_alerts_queue(hosts, alerts, groups)" do
    let(:interferon) {Interferon::Interferon.new(nil,nil,nil,nil,true,0)}

    before do
      allow_any_instance_of(MockAlert).to receive(:evaluate)
    end

    it 'adds people to alerts when notify.groups{} is used' do
      added = create_test_alert('name1', 'testquery3', '')
      groups = {'a' => ['foo', 'bar']}
      result = interferon.build_alerts_queue(['host'], [added], groups)
      expect(result['name1'][1]).to eq(['foo', 'bar'].to_set)
    end

    context 'when notify.fallback_groups{} is used' do
      it 'adds fallback people to alerts when no other groups are found' do
        added = create_test_alert_with_groups_and_fallback_groups(['nonexistent_group'],['fallback_group'])
        groups = {'fallback_group' => ['biz', 'baz']}
        result = interferon.build_alerts_queue(['host'], [added], groups)
        expect(result['name1'][1]).to eq(['biz', 'baz'].to_set)
      end

      it 'does not add fallback people to alerts when other groups are found' do
        added = create_test_alert_with_groups_and_fallback_groups(['group'],['fallback_group'])
        groups = {}
        groups['group'] = ['foo', 'bar']
        groups['fallback_groups'] = ['biz', 'baz']
        result = interferon.build_alerts_queue(['host'], [added], groups)
        expect(result['name1'][1]).to eq(['foo', 'bar'].to_set)
      end
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

      interferon.update_alerts_on_destination(
        dest,
        ['host'],
        [alerts['name1'], alerts['name2']],
        {}
      )
    end

    it 'runs added alerts' do
      alerts = mock_existing_alerts
      added = create_test_alert('name3', 'testquery3', '')
      expect(dest).to receive(:create_alert).once.and_call_original
      expect(dest).to receive(:remove_alert_by_id).with('3').once

      interferon.update_alerts_on_destination(
        dest,
        ['host'],
        [alerts['name1'], alerts['name2'], added],
        {}
      )
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
      alert1 = mock_alert_json('name1', 'testquery1', '', nil, [1, 2, 3])
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
      alert1 = mock_alert_json('name1', 'testquery1', '', nil, [1, 2, 3])
      alert2 = mock_alert_json('name2', 'testquery2', '')
      existing_alerts = {'name1' => alert1, 'name2' => alert2}
      dest = MockDest.new(existing_alerts)
      allow(dest).to receive(:remove_alert)
      allow(dest).to receive(:remove_alert_by_id)
      allow(dest).to receive(:report_stats)

      added = create_test_alert('name1', 'testquery1', '')

      # Since we change id to nil we will not be attempting to delete duplicate alerts
      # during dry run
      expect(dest).to_not receive(:remove_alert).with(existing_alerts['name1'])
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

      interferon.update_alerts_on_destination(
        dest,
        ['host'],
        [alerts['name1'], alerts['name2'], added],
        {}
      )
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
      alert1 = mock_alert_json('name1', 'testquery1', '', nil, [1, 2, 3])
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
      alert1 = mock_alert_json('name1', 'testquery1', '', nil, [1, 2, 3])
      alert2 = mock_alert_json('name2', 'testquery2', '')
      existing_alerts = {'name1' => alert1, 'name2' => alert2}
      dest = MockDest.new(existing_alerts)
      allow(dest).to receive(:report_stats)

      added = create_test_alert('name1', 'testquery1', '')

      expect(dest).to receive(:remove_alert).with(mock_alert_json(
        'name1',
        'testquery1',
        '',
        nil,
        [2, 3]
      ))
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

  DEFAULT_OPTIONS = {
    'notify_audit' => true,
    'notify_no_data' => false,
    'silenced' => {},
    'thresholds' => nil,
    'no_data_timeframe' => nil,
    'require_full_window' => nil,
    'timeout' => nil,
  }

  def mock_alert_json(name, datadog_query, message, type="metric alert", id=nil, options={})
    options = DEFAULT_OPTIONS.merge(options)

    {
      'name'=> name,
      'query' => datadog_query,
      'type' => type,
      'message' => message,
      'id' => id.nil? ? [name[-1]] : id,
      'options' => options,
    }
  end

  def create_test_alert(name, datadog_query, message, options={})
    options = DEFAULT_OPTIONS.merge(options)

    alert_dsl = AlertDSL.new({})

    metric_dsl = MetricDSL.new({})
    metric_dsl.datadog_query(datadog_query)
    alert_dsl.instance_variable_set(:@metric, metric_dsl)

    notify_dsl = NotifyDSL.new({})
    notify_dsl.groups(['a'])
    alert_dsl.instance_variable_set(:@notify, notify_dsl)

    alert_dsl.name(name)
    alert_dsl.applies(true)
    alert_dsl.message(message)

    alert_dsl.no_data_timeframe(options['no_data_timeframe'])
    alert_dsl.notify_no_data(options['notify_no_data'])
    alert_dsl.require_full_window(options['require_full_window'])
    alert_dsl.thresholds(options['thresholds'])
    alert_dsl.timeout(options['timeout'])
    alert_dsl.silenced(options['silenced'])

    MockAlert.new(alert_dsl)
  end

  def create_test_alert_with_groups_and_fallback_groups(groups=[], fallback_groups=[])
    alert_dsl = AlertDSL.new({})

    notify_dsl = NotifyDSL.new({})
    notify_dsl.groups(groups)
    notify_dsl.fallback_groups(fallback_groups)
    alert_dsl.instance_variable_set(:@notify, notify_dsl)

    alert_dsl.name('name1')
    alert_dsl.applies(true)

    MockAlert.new(alert_dsl)
  end
end
