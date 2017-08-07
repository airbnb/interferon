require 'spec_helper'
require 'helpers/mock_alert'
require 'interferon/destinations/datadog'

include Interferon

describe Interferon::Destinations::Datadog do
  let(:the_existing_alerts) { mock_existing_alerts }
  let(:dest) { MockDest.new(the_existing_alerts) }

  context 'when checking alerts have changed' do
    it 'detects a change if alert message is different' do
      alert1 = create_test_alert('name1', 'testquery', 'message1')
      alert2 = mock_alert_json('name2', 'testquery', 'message2')

      expect(Interferon::Destinations::Datadog.same_alerts(alert1, [], alert2)).to be false
    end

    it 'detects a change if datadog query is different' do
      alert1 = create_test_alert('name1', 'testquery1', 'message1')
      alert2 = mock_alert_json('name2', 'testquery2', 'message2')

      expect(Interferon::Destinations::Datadog.same_alerts(alert1, [], alert2)).to be false
    end

    it 'detects a change if alert notify_no_data is different' do
      alert1 = create_test_alert('name1', 'testquery1', 'message1', notify_no_data: false)
      alert2 = mock_alert_json('name2', 'testquery2', 'message2', nil, [1], notify_no_data: true)

      expect(Interferon::Destinations::Datadog.same_alerts(alert1, [], alert2)).to be false
    end

    it 'detects a change if alert silenced is different' do
      alert1 = create_test_alert('name1', 'testquery1', 'message1', silenced: true)
      alert2 = mock_alert_json('name2', 'testquery2', 'message2', nil, [1], silenced: {})

      expect(Interferon::Destinations::Datadog.same_alerts(alert1, [], alert2)).to be false
    end

    it 'detects a change if alert no_data_timeframe is different' do
      alert1 = create_test_alert('name1', 'testquery1', 'message1', no_data_timeframe: nil)
      alert2 = mock_alert_json('name2', 'testquery2', 'message2', nil, [1], no_data_timeframe: 60)

      expect(Interferon::Destinations::Datadog.same_alerts(alert1, [], alert2)).to be false
    end

    it 'detects a change if alert require_full_window is different' do
      alert1 = create_test_alert('name1', 'testquery1', 'message1', require_full_window: false)
      alert2 = mock_alert_json(
        'name2', 'testquery2', 'message2', nil, [1], require_full_window: true
      )

      expect(Interferon::Destinations::Datadog.same_alerts(alert1, [], alert2)).to be false
    end

    it 'detects a change if alert evaluation_delay is different' do
      alert1 = create_test_alert('name1', 'testquery1', 'message1', evaluation_delay: nil)
      alert2 = mock_alert_json('name2', 'testquery2', 'message2', nil, [1], evaluation_delay: 300)

      expect(Interferon::Destinations::Datadog.same_alerts(alert1, [], alert2)).to be false
    end

    it 'does not detect a change when alert datadog query and message are the same' do
      alert1 = create_test_alert('name1', 'testquery1', 'message1')
      alert2 = mock_alert_json(
        'name1', 'testquery1', "message1\nThis alert was created via the alerts framework"
      )

      expect(Interferon::Destinations::Datadog.same_alerts(alert1, [], alert2)).to be true
    end
  end

  context 'dry_run_update_alerts_on_destination' do
    let(:interferon) { Interferon::Interferon.new({}, true, 0) }

    before do
      allow_any_instance_of(MockAlert).to receive(:evaluate)
      allow(dest).to receive(:remove_alert)
      allow(dest).to receive(:report_stats)
    end

    it 'does not re-run existing alerts' do
      mock_alerts = mock_existing_alerts
      expect(dest).not_to receive(:create_alert)

      alerts_queue, _error_count = interferon.build_alerts_queue(
        ['host'],
        [mock_alerts['name1'], mock_alerts['name2']].map { |x| test_alert_from_json(x) },
        {}
      )

      interferon.update_alerts_on_destination(dest, alerts_queue)
    end

    it 'runs added alerts' do
      mock_alerts = mock_existing_alerts
      alerts = [mock_alerts['name1'], mock_alerts['name2']].map { |x| test_alert_from_json(x) }
      alerts << create_test_alert('name3', 'testquery3', '')

      alerts_queue, _error_count = interferon.build_alerts_queue(['host'], alerts, {})

      expect(dest).to receive(:create_alert).once.and_call_original

      interferon.update_alerts_on_destination(dest, alerts_queue)
    end

    it 'runs updated alerts' do
      added = create_test_alert('name1', 'testquery3', '')
      alerts_queue, _error_count = interferon.build_alerts_queue(['host'], [added], {})
      expect(dest).to receive(:create_alert).once.and_call_original

      interferon.update_alerts_on_destination(dest, alerts_queue)
    end

    it 'does not delete old alerts' do
      expect(dest).to_not receive(:remove_alert)
      alerts_queue, _error_count = interferon.build_alerts_queue(['host'], [], {})

      interferon.update_alerts_on_destination(dest, alerts_queue)
    end

    it 'does not delete duplicate old alerts' do
      alert1 = mock_alert_json('name1', 'testquery1', '', nil, [1, 2, 3])
      alert2 = mock_alert_json('name2', 'testquery2', '')
      existing_alerts = { 'name1' => alert1, 'name2' => alert2 }

      dest = MockDest.new(existing_alerts)
      allow(dest).to receive(:report_stats)

      alerts_queue, _error_count = interferon.build_alerts_queue(['host'], [], {})

      expect(dest).to_not receive(:remove_alert)

      interferon.update_alerts_on_destination(dest, alerts_queue)
    end

    it 'does not delete duplicate old alerts when creating new alert' do
      alert1 = mock_alert_json('name1', 'testquery1', '', nil, [1, 2, 3])
      alert2 = mock_alert_json('name2', 'testquery2', '')
      existing_alerts = { 'name1' => alert1, 'name2' => alert2 }

      dest = MockDest.new(existing_alerts)
      allow(dest).to receive(:report_stats)

      added = create_test_alert('name1', 'testquery1', '')
      alerts_queue, _error_count = interferon.build_alerts_queue(['host'], [added], {})

      expect(dest).to_not receive(:remove_alert)

      interferon.update_alerts_on_destination(dest, alerts_queue)
    end
  end

  context 'update_alerts_on_destination' do
    let(:interferon) { Interferon::Interferon.new({}, false, 0) }

    before do
      allow_any_instance_of(MockAlert).to receive(:evaluate)
      allow(dest).to receive(:remove_alert)
      allow(dest).to receive(:report_stats)
    end

    it 'does not re-run existing alerts' do
      mock_alerts = mock_existing_alerts
      expect(dest).not_to receive(:create_alert)

      alerts_queue, _error_count = interferon.build_alerts_queue(
        ['host'],
        [mock_alerts['name1'], mock_alerts['name2']].map { |x| test_alert_from_json(x) },
        {}
      )

      interferon.update_alerts_on_destination(dest, alerts_queue)
    end

    it 'runs added alerts' do
      mock_alerts = mock_existing_alerts
      alerts = [mock_alerts['name1'], mock_alerts['name2']].map { |x| test_alert_from_json(x) }
      alerts << create_test_alert('name3', 'testquery3', '')

      alerts_queue, _error_count = interferon.build_alerts_queue(['host'], alerts, {})

      expect(dest).to receive(:create_alert).once.and_call_original

      interferon.update_alerts_on_destination(dest, alerts_queue)
    end

    it 'runs updated alerts' do
      added = create_test_alert('name1', 'testquery3', '')
      alerts_queue, _error_count = interferon.build_alerts_queue(['host'], [added], {})
      expect(dest).to receive(:create_alert).once.and_call_original

      interferon.update_alerts_on_destination(dest, alerts_queue)
    end

    it 'deletes old alerts' do
      alerts = mock_existing_alerts
      alerts_queue, _error_count = interferon.build_alerts_queue(['host'], [], {})
      expect(dest).to receive(:remove_alert).with(alerts['name1'])
      expect(dest).to receive(:remove_alert).with(alerts['name2'])

      interferon.update_alerts_on_destination(dest, alerts_queue)
    end

    it 'deletes duplicate old alerts' do
      alert1 = mock_alert_json('name1', 'testquery1', '', nil, [1, 2, 3])
      alert2 = mock_alert_json('name2', 'testquery2', '')
      existing_alerts = { 'name1' => alert1, 'name2' => alert2 }
      dest = MockDest.new(existing_alerts)
      allow(dest).to receive(:remove_alert)
      allow(dest).to receive(:report_stats)

      alerts_queue, _error_count = interferon.build_alerts_queue(['host'], [], {})

      expect(dest).to receive(:remove_alert).with(existing_alerts['name1'])
      expect(dest).to receive(:remove_alert).with(existing_alerts['name2'])

      interferon.update_alerts_on_destination(dest, alerts_queue)
    end

    it 'deletes duplicate old alerts when creating new alert' do
      alert1 = mock_alert_json('name1', 'testquery1', '', nil, [1, 2, 3])
      alert2 = mock_alert_json('name2', 'testquery2', '')
      existing_alerts = { 'name1' => alert1, 'name2' => alert2 }
      dest = MockDest.new(existing_alerts)
      allow(dest).to receive(:report_stats)

      added = create_test_alert('name1', 'testquery1', '')
      alerts_queue, _error_count = interferon.build_alerts_queue(['host'], [added], {})

      expect(dest).to receive(:remove_alert).with(
        mock_alert_json('name1', 'testquery1', '', nil, [2, 3])
      )
      expect(dest).to receive(:remove_alert).with(existing_alerts['name2'])

      interferon.update_alerts_on_destination(dest, alerts_queue)
    end
  end

  def mock_existing_alerts
    mock_message = Interferon::Destinations::Datadog::ALERT_KEY
    alert1 = mock_alert_json('name1', 'testquery1', mock_message)
    alert2 = mock_alert_json('name2', 'testquery2', mock_message)
    { 'name1' => alert1, 'name2' => alert2 }
  end

  class MockDest < Interferon::Destinations::Datadog
    attr_reader :existing_alerts

    def initialize(the_existing_alerts)
      @existing_alerts = the_existing_alerts
    end

    def create_alert(alert, _people)
      name = alert['name']
      id = [alert['name'][-1]]
      [name, id]
    end
  end

  DEFAULT_OPTIONS = {
    'evaluation_delay' => nil,
    'notify_audit' => false,
    'notify_no_data' => false,
    'silenced' => {},
    'thresholds' => nil,
    'no_data_timeframe' => nil,
    'require_full_window' => nil,
    'timeout' => nil,
  }.freeze

  def mock_alert_json(name, datadog_query, message, type = 'metric alert', id = nil, options = {})
    options = DEFAULT_OPTIONS.merge(options)

    {
      'name' => name,
      'query' => datadog_query,
      'type' => type,
      'message' => message,
      'id' => id.nil? ? [name[-1]] : id,
      'options' => options,
    }
  end

  def test_alert_from_json(mock_alert_json)
    create_test_alert(
      mock_alert_json['name'],
      mock_alert_json['query'],
      mock_alert_json['message'].sub(/#{Interferon::Destinations::Datadog::ALERT_KEY}$/, ''),
      mock_alert_json['options']
    )
  end

  def create_test_alert(name, datadog_query, message, options = {})
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
    alert_dsl.evaluation_delay(options['evaluation_delay'])
    alert_dsl.require_full_window(options['require_full_window'])
    alert_dsl.thresholds(options['thresholds'])
    alert_dsl.timeout(options['timeout'])
    alert_dsl.silenced(options['silenced'])

    MockAlert.new(alert_dsl)
  end
end
