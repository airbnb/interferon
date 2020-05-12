# frozen_string_literal: true

require 'spec_helper'
require 'helpers/mock_alert'
require 'interferon/destinations/datadog'

include Interferon

describe Interferon::Destinations::Datadog do
  let(:the_existing_alerts) { mock_existing_alerts }
  let(:dest) { MockDest.new(the_existing_alerts) }
  let(:datadog) do
    Interferon::Destinations::Datadog.new(
      'app_key' => 'TEST_APP_KEY', 'api_key' => 'TEST_API_KEY'
    )
  end

  shared_examples_for 'alert_option' do |alert_option, same_value, different_value, alert_dsl|
    let(:json_message) { 'message' + "\n#{datadog.alert_key}" }
    let(:alert) do
      alert_dsl_path = alert_dsl.nil? ? alert_option : alert_dsl
      create_test_alert('name1', 'testquery', 'message', ['tag1'], alert_dsl_path => same_value)
    end
    let(:alert_same) do
      mock_alert_json(
        'name2', 'testquery', json_message, 'metric alert',
        [1], ['tag1'], alert_option => same_value
      )
    end
    let(:alert_diff) do
      mock_alert_json(
        'name2', 'testquery', json_message, 'metric_alert',
        [1], ['tag1'], alert_option => different_value
      )
    end

    context 'when the options are the same' do
      it 'should return true' do
        expect(datadog.same_alerts(alert, [], alert_same)).to be true
      end
    end

    context 'when the options are the different' do
      it 'should return false' do
        expect(datadog.same_alerts(alert, [], alert_diff)).to be false
      end
    end
  end

  describe '#same_alerts' do
    let(:json_message) { 'message' + "\n#{datadog.alert_key}" }

    it 'detects a no change if alert message is the same' do
      alert1 = create_test_alert('name1', 'testquery', 'message')
      alert2 = mock_alert_json('name2', 'testquery', json_message)

      expect(datadog.same_alerts(alert1, [], alert2)).to be true
    end

    it 'detects a change if alert message is different' do
      alert1 = create_test_alert('name1', 'testquery', 'message2')
      alert2 = mock_alert_json('name2', 'testquery', json_message)

      expect(datadog.same_alerts(alert1, [], alert2)).to be false
    end

    it 'detects no change if datadog query is the same' do
      alert1 = create_test_alert('name1', 'testquery', 'message')
      alert2 = mock_alert_json('name2', 'testquery', json_message)

      expect(datadog.same_alerts(alert1, [], alert2)).to be true
    end

    it 'detects a change if datadog query is different' do
      alert1 = create_test_alert('name1', 'testquery1', 'message')
      alert2 = mock_alert_json('name2', 'testquery2', json_message)

      expect(datadog.same_alerts(alert1, [], alert2)).to be false
    end

    it 'detects a change if datadog tags are different' do
      alert1 = create_test_alert('name1', 'testquery1', 'message', ['tag1'])
      alert2 = mock_alert_json('name2', 'testquery1', json_message, ['tag2'])

      expect(datadog.same_alerts(alert1, [], alert2)).to be false
    end

    context 'notify_no_data option' do
      it_behaves_like('alert_option', 'notify_no_data', true, false)
    end

    context 'silenced option' do
      it_behaves_like('alert_option', 'silenced', { 'silenced' => '*' }, false)
    end

    context 'no_data_timeframe option' do
      it_behaves_like('alert_option', 'no_data_timeframe', nil, 60)
      it_behaves_like('alert_option', 'no_data_timeframe', 120, 60)
    end

    context 'require_full_window option' do
      it_behaves_like('alert_option', 'require_full_window', false, true)
    end

    context 'evaluation_delay option' do
      it_behaves_like('alert_option', 'evaluation_delay', nil, 300)
      it_behaves_like('alert_option', 'evaluation_delay', 600, 400)
    end

    context 'new_host_delay option' do
      it_behaves_like('alert_option', 'new_host_delay', 600, 400)
    end

    context 'thresholds option' do
      it_behaves_like('alert_option', 'thresholds', nil, 'critical' => 1)
      it_behaves_like('alert_option', 'thresholds', { 'critical' => 2 }, 'critical' => 1)
    end

    context 'thresholds option with symbols' do
      it 'converts symbols in thresholds hash keys to strings' do
        alert = create_test_alert(
          'name1', 'testquery', 'message', [], 'thresholds' => { critical: 1 }
        )
        alert_same = mock_alert_json(
          'name2', 'testquery', json_message, 'metric alert',
          [1], [], 'thresholds' => { 'critical' => 1 }
        )
        expect(datadog.same_alerts(alert, [], alert_same)).to be true
      end
    end

    context 'timeout_h option' do
      it_behaves_like('alert_option', 'timeout_h', nil, 3600)
    end

    context 'include_tags option' do
      it_behaves_like('alert_option', 'include_tags', nil, false, 'notify' => 'include_tags')
      it_behaves_like('alert_option', 'include_tags', true, false, 'notify' => 'include_tags')
    end

    context 'renotify_interval option' do
      it_behaves_like('alert_option', 'renotify_interval', nil, 30, 'notify' => 'renotify_interval')
      it_behaves_like('alert_option', 'renotify_interval', 60, 30, 'notify' => 'renotify_interval')
    end

    context 'escalation_message option' do
      it_behaves_like(
        'alert_option', 'escalation_message', nil, '', 'notify' => 'escalation_message'
      )
      it_behaves_like(
        'alert_option', 'escalation_message', 'foo', 'bar', 'notify' => 'escalation_message'
      )
    end

    context 'notify_recovery option' do
      it 'does not add is_recovery to the message body when true' do
        alert = create_test_alert(
          'name1', 'testquery', 'message', [], { 'notify' => 'recovery' } => true
        )
        alert_same = mock_alert_json(
          'name2', 'testquery', json_message, 'metric alert', [1], [], {}
        )
        expect(datadog.same_alerts(alert, [], alert_same)).to be true
      end

      it 'adds is_recovery to the message body when false' do
        alert = create_test_alert(
          'name1', 'testquery', 'message', { 'notify' => 'recovery' } => false
        )
        alert_same = mock_alert_json(
          'name2', 'testquery', json_message, 'metric alert', [1], {}
        )
        expect(datadog.same_alerts(alert, [], alert_same)).to be false
      end
    end

    context 'notify_audit option' do
      it_behaves_like('alert_option', 'notify_audit', true, false, 'notify' => 'audit')
    end

    it 'detects no change if alert silenced is true compared to wildcard hash' do
      alert1 = create_test_alert('name1', 'testquery',
                                 'message', ['tag1'], 'silenced' => true)
      alert2 = mock_alert_json(
        'name2', 'testquery', json_message, 'metric alert',
        [1], ['tag1'], 'silenced' => { '*' => nil }
      )

      expect(datadog.same_alerts(alert1, [], alert2)).to be true
    end
  end

  context '#build_alerts_queue(hosts, alerts, groups)' do
    let(:interferon) { Interferon::Interferon.new({ 'processes' => 0 }, true) }

    before do
      allow_any_instance_of(MockAlert).to receive(:evaluate)
    end

    it 'adds people to alerts when notify.groups{} is used' do
      added = create_test_alert('name1', 'testquery3', '')
      groups = { 'a' => %w[foo bar] }
      result = interferon.build_alerts_queue(['host'], [added], groups)
      expect(result[0]['name1'][1]).to eq(%w[foo bar].to_set)
    end

    context 'when notify.fallback_groups{} is used' do
      it 'adds fallback people to alerts when no other groups are found' do
        added = create_test_alert_with_groups_and_fallback_groups(
          ['nonexistent_group'],
          ['fallback_group']
        )
        groups = { 'fallback_group' => %w[biz baz] }
        result = interferon.build_alerts_queue(['host'], [added], groups)
        expect(result[0]['name1'][1]).to eq(%w[biz baz].to_set)
      end

      it 'does not add fallback people to alerts when other groups are found' do
        added = create_test_alert_with_groups_and_fallback_groups(['group'], ['fallback_group'])
        groups = {}
        groups['group'] = %w[foo bar]
        groups['fallback_groups'] = %w[biz baz]
        result = interferon.build_alerts_queue(['host'], [added], groups)
        expect(result[0]['name1'][1]).to eq(%w[foo bar].to_set)
      end
    end
  end

  context 'dry_run_update_alerts_on_destination' do
    let(:interferon) { Interferon::Interferon.new({ 'processes' => 0 }, true) }

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
      expect(dest).to_not receive(:remove_datadog_alert)
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

      expect(dest).to_not receive(:remove_datadog_alert)

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

      expect(dest).to_not receive(:remove_datadog_alert)

      interferon.update_alerts_on_destination(dest, alerts_queue)
    end
  end

  context 'update_alerts_on_destination' do
    let(:interferon) { Interferon::Interferon.new({ 'processes' => 0 }, false) }

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
    mock_message = datadog.alert_key
    alert1 = mock_alert_json('name1', 'testquery1', mock_message)
    alert2 = mock_alert_json('name2', 'testquery2', mock_message)
    { 'name1' => alert1, 'name2' => alert2 }
  end

  class MockDest < Interferon::Destinations::Datadog
    attr_reader :existing_alerts

    def initialize(the_existing_alerts)
      @existing_alerts = the_existing_alerts
      @alert_key = ALERT_KEY
    end

    def create_alert(alert, _people)
      name = alert['name']
      id = [alert['name'][-1]]
      [name, id]
    end
  end

  DEFAULT_OPTIONS = {
    'evaluation_delay' => nil,
    'new_host_delay' => 300,
    'notify_audit' => false,
    'notify_no_data' => false,
    'silenced' => {},
    'thresholds' => nil,
    'no_data_timeframe' => nil,
    'require_full_window' => nil,
    'timeout' => nil,
    'locked' => false,
  }.freeze

  def mock_alert_json(name, datadog_query, message, type = 'metric alert',
                      id = nil, tags = [], options = {})
    options = DEFAULT_OPTIONS.merge(options)
    {
      'name' => name,
      'query' => datadog_query,
      'type' => type,
      'message' => message,
      'id' => id.nil? ? [name[-1]] : id,
      'options' => options,
      'tags' => tags,
    }
  end

  def test_alert_from_json(mock_alert_json)
    create_test_alert(
      mock_alert_json['name'],
      mock_alert_json['query'],
      mock_alert_json['message'].sub(/#{datadog.alert_key}$/, ''),
      mock_alert_json['tags'],
      mock_alert_json['options']
    )
  end

  def create_test_alert(name, datadog_query, message, tags = [], options = {})
    options = DEFAULT_OPTIONS.merge(options)

    alert_dsl = AlertDSL.new({})

    metric_dsl = MetricDSL.new({})
    metric_dsl.datadog_query(datadog_query)
    alert_dsl.instance_variable_set(:@metric, metric_dsl)

    notify_dsl = NotifyDSL.new({})
    notify_dsl.groups(['a'])
    notify_dsl.audit(options['notify' => 'audit'])
    notify_dsl.escalation_message(options['notify' => 'escalation_message'])
    notify_dsl.include_tags(options['notify' => 'include_tags'])
    notify_dsl.recovery(options['notify' => 'recovery'])
    notify_dsl.renotify_interval(options['notify' => 'renotify_interval'])

    alert_dsl.instance_variable_set(:@notify, notify_dsl)

    alert_dsl.name(name)
    alert_dsl.applies(true)
    alert_dsl.message(message)
    alert_dsl.target('mockdest')

    alert_dsl.no_data_timeframe(options['no_data_timeframe'])
    alert_dsl.notify_no_data(options['notify_no_data'])
    alert_dsl.evaluation_delay(options['evaluation_delay'])
    alert_dsl.new_host_delay(options['new_host_delay'])
    alert_dsl.require_full_window(options['require_full_window'])
    alert_dsl.thresholds(options['thresholds'])
    alert_dsl.timeout(options['timeout'])
    alert_dsl.silenced(options['silenced'])
    alert_dsl.tags(tags)

    MockAlert.new(alert_dsl)
  end

  def create_test_alert_with_groups_and_fallback_groups(groups = [], fallback_groups = [])
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
