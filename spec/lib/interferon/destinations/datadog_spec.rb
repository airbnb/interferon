# frozen_string_literal: true

require 'spec_helper'
require 'interferon/destinations/datadog'

describe Interferon::Destinations::Datadog do
  let(:retries) { 3 }
  let(:max_mute_minutes) { 60 }
  let(:base_datadog_config) do
    {
      'api_key' => 'TEST_API_KEY',
      'app_key' => 'TEST_APP_KEY',
      'retries' => retries,
      'retry_base_delay' => 0,
    }
  end
  let(:datadog) do
    Interferon::Destinations::Datadog.new(
      base_datadog_config
    )
  end
  let(:datadog_dry_run) do
    Interferon::Destinations::Datadog.new(
      base_datadog_config.merge('dry_run' => true)
    )
  end
  let(:datadog_max_mute) do
    Interferon::Destinations::Datadog.new(
      base_datadog_config.merge('max_mute_minutes' => max_mute_minutes)
    )
  end
  let(:datadog_alert_key) do
    Interferon::Destinations::Datadog.new(
      base_datadog_config.merge('alert_key' => mock_custom_alert_key)
    )
  end
  let(:mock_custom_alert_key) { 'My custom alert key' }
  let(:mock_alert_id) { 123 }
  let(:mock_alert) do
    {
      'id' => [mock_alert_id],
      'name' => 'Test Alert',
      'message' => 'Test Message',
      'metric' => { 'datadog_query' => 'avg:metric{*}' },
      'silenced' => {},
      'notify' => {},
      'tags' => %w[foo bar],
    }
  end
  let(:mock_people) { %w[foo bar baz] }
  let(:mock_response) do
    {
      'Test Alert' => {
        'id' => 567,
        'name' => 'Test Alert',
        'message' => 'Test Message',
        'query' => 'avg:metric{*}',
        'tags' => %w[foo bar],
        'options' => {
          'silenced' => {},
        },
      },
    }
  end

  describe '.fetch_existing_alerts' do
    it 'calls dogapi get_all_monitors' do
      expect_any_instance_of(Dogapi::Client).to receive(:get_all_monitors).and_return([200, []])
      datadog.fetch_existing_alerts
    end
  end

  describe '.existing_alerts' do
    it 'retries dogapi get_all_monitors' do
      return_vals = [[400, '']] * (retries + 1)
      expect_any_instance_of(Dogapi::Client).to receive(:get_all_monitors).and_return(*return_vals)
      expect { datadog.existing_alerts }.to raise_error RuntimeError
    end
  end

  describe '.create_alert' do
    it 'calls dogapi monitor' do
      expect_any_instance_of(Dogapi::Client).to receive(:monitor).and_return([200, ''])
      expect(datadog).to receive(:existing_alerts).and_return({})
      datadog.create_alert(mock_alert, mock_people)
    end

    it 'calls dogapi update_monitor when alert name is found' do
      expect_any_instance_of(Dogapi::Client).to receive(:update_monitor).and_return([200, ''])
      expect(datadog).to receive(:existing_alerts).and_return(mock_response)
      datadog.create_alert(mock_alert, mock_people)
    end

    it 'calls dogapi to delete and recreate when alert name is found' do
      expect_any_instance_of(Dogapi::Client).to receive(:delete_monitor).and_return([200, ''])
      expect_any_instance_of(Dogapi::Client).to receive(:monitor).and_return([200, ''])
      mock_response['Test Alert']['type'] = 'event_alert'
      expect(datadog).to receive(:existing_alerts).and_return(mock_response)
      datadog.create_alert(mock_alert, mock_people)
    end

    it 'calls dogapi to unmute when existing alert is muted' do
      expect_any_instance_of(Dogapi::Client).to receive(:update_monitor).and_return([200, ''])
      expect_any_instance_of(Dogapi::Client).to receive(:unmute_monitor).and_return([200, ''])
      mock_response['Test Alert']['options']['silenced'] = { '*' => nil }
      expect(datadog).to receive(:existing_alerts).and_return(mock_response)
      datadog.create_alert(mock_alert, mock_people)
    end

    it 'calls dogapi to unmute when existing mute exceed max_mute_minutes' do
      expect_any_instance_of(Dogapi::Client).to receive(:update_monitor).and_return([200, ''])
      expect_any_instance_of(Dogapi::Client).to receive(:unmute_monitor).and_return([200, ''])
      mock_response['Test Alert']['options']['silenced'] = {
        '*' => Time.now.to_i + max_mute_minutes * 60 + 10,
      }
      expect(datadog_max_mute).to receive(:existing_alerts).and_return(mock_response)
      datadog_max_mute.create_alert(mock_alert, mock_people)
    end

    it 'calls dogapi to keep mute when existing mute does not exceed max_mute_minutes' do
      expect_any_instance_of(Dogapi::Client).to receive(:update_monitor).and_return([200, ''])
      expect_any_instance_of(Dogapi::Client).not_to receive(:unmute_monitor)
      mock_response['Test Alert']['options']['silenced'] = {
        '*' => Time.now.to_i + max_mute_minutes * 60 - 10,
      }
      expect(datadog_max_mute).to receive(:existing_alerts).and_return(mock_response)
      datadog_max_mute.create_alert(mock_alert, mock_people)
    end

    it 'calls validate monitor in dry-run' do
      expect_any_instance_of(Dogapi::Client).to receive(:validate_monitor).and_return([200, ''])
      expect(datadog_dry_run).to receive(:existing_alerts).and_return(mock_response)
      datadog_dry_run.create_alert(mock_alert, mock_people)
    end
  end

  describe '.remove_alert' do
    it 'calls dogapi delete_monitor with the correct alert id' do
      mock_alert['message'] += Interferon::Destinations::Datadog::ALERT_KEY
      expect_any_instance_of(Dogapi::Client).to receive(:delete_monitor)
        .with(mock_alert_id).and_return([200, ''])
      datadog.remove_alert(mock_alert)
    end

    it 'does not call dogapi delete_monitor in dry_run' do
      mock_alert['message'] += Interferon::Destinations::Datadog::ALERT_KEY
      expect_any_instance_of(Dogapi::Client).to_not receive(:delete_monitor)
      datadog_dry_run.remove_alert(mock_alert)
    end

    it 'does not call dogapi delete_monitor when ALERT_KEY is missing' do
      expect_any_instance_of(Dogapi::Client).to_not receive(:delete_monitor)
      datadog.remove_alert(mock_alert)
    end
  end

  describe '.generate_message' do
    let(:message) { 'test message' }
    let(:people) { %w[userA userB] }

    it 'adds the ALERT_KEY to the message' do
      expect(datadog.generate_message(message, people)).to include(
        Interferon::Destinations::Datadog::ALERT_KEY
      )
    end

    it 'prefers a custom alert_key if provided' do
      expect(datadog_alert_key.generate_message(message, people)).to include(
        mock_custom_alert_key
      )
    end

    it 'adds a mention to people' do
      expect(datadog.generate_message(message, people)).to include(
        *people.map { |person| "@#{person}" }
      )
    end

    it 'does not add ^is_recovery template variable when notify_recovery is true' do
      expect(
        datadog.generate_message(
          message, people, notify_recovery: true
        )
      ).not_to include('{{^is_recovery}}')
    end

    it 'adds a ^is_recovery template variable when notify_recovery is false' do
      expect(
        datadog.generate_message(
          message, people, notify_recovery: false
        )
      ).to include('{{^is_recovery}}')
    end
  end

  describe '#retryable' do
    class RetryTester
      def foo; end
    end

    let!(:retry_tester) { RetryTester.new }

    it 'completes early if successful' do
      expect(retry_tester).to receive(:foo).once

      datadog.retryable do
        retry_tester.foo
      end
    end

    it 'retries up to 6 times by default if error is Net::OpenTimeout' do
      expect(retry_tester).to receive(:foo).exactly(4).times
      allow(retry_tester).to receive(:foo).and_raise(Net::OpenTimeout)

      expect do
        datadog.retryable do
          retry_tester.foo
        end
      end.to raise_error(Net::OpenTimeout)
    end

    it 'retries up to 6 times by default if error is Net::ReadTimeout' do
      expect(retry_tester).to receive(:foo).exactly(4).times
      allow(retry_tester).to receive(:foo).and_raise(Net::ReadTimeout)

      expect do
        datadog.retryable do
          retry_tester.foo
        end
      end.to raise_error(Net::ReadTimeout)
    end

    it 'will raise any error that is not Net::Open/ReadTimout without retrying' do
      expect(retry_tester).to receive(:foo).exactly(1).times
      allow(retry_tester).to receive(:foo).and_raise(StandardError)

      expect do
        datadog.retryable do
          retry_tester.foo
        end
      end.to raise_error(StandardError)
    end

    context 'with custom config' do
      let(:base_datadog_config) do
        {
          'api_key' => 'TEST_API_KEY',
          'app_key' => 'TEST_APP_KEY',
          'retries' => 10,
          'retry_base_delay' => 0,
        }
      end

      it 'retries request 10 times' do
        expect(retry_tester).to receive(:foo).exactly(11).times
        allow(retry_tester).to receive(:foo).and_raise(Net::OpenTimeout)

        expect do
          datadog.retryable do
            retry_tester.foo
          end
        end.to raise_error(Net::OpenTimeout)
      end
    end
  end
end
