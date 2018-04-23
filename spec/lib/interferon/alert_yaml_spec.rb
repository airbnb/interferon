# frozen_string_literal: true

require 'spec_helper'
require 'interferon/alert_yaml'

describe Interferon::AlertYaml do
  let(:sample_alert_yml_path) { './spec/fixtures/files/sample_alert.yml' }
  describe '#initialize' do
    it 'reads a file' do
      expect(File).to receive(:read).with(sample_alert_yml_path)
      Interferon::AlertYaml.new(sample_alert_yml_path)
    end
  end

  context 'with hostinfo' do
    let(:hostinfo) { { application_name: 'Sample Application' } }

    before do
      @alert_yml = Interferon::AlertYaml.new(sample_alert_yml_path)
    end

    describe '#evaluate' do
      it 'loads a YAML file' do
        expect(YAML).to receive(:safe_load).and_call_original
        @alert_yml.evaluate(hostinfo)
      end

      it 'adds interferon tag to name' do
        alert = @alert_yml.evaluate(hostinfo)
        expect(alert['name'].end_with?('[Interferon]')).to be true
      end

      describe '#match_matcher' do
        it 'matches a positive glob' do
          hostinfo = { role: 'test-app' }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.match_matcher('role' => 'test-*')).to be true
        end

        it 'matches a positive exact match' do
          hostinfo = { role: 'test-app' }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.match_matcher('role' => 'test-app')).to be true
        end

        it 'matches multiple postive matches' do
          hostinfo = { role: 'test-app', region: 'a' }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.match_matcher('role' => 'test-*', 'region' => 'a')).to be true
        end

        it 'does not match negative matches' do
          hostinfo = { role: 'test' }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.match_matcher('role' => 'test-app')).to be false
        end

        it 'does not match multiple matches when one is missing from hostinfo' do
          hostinfo = { role: 'test-app' }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.match_matcher('role' => 'test-*', 'region' => 'a')).to be false
        end
      end

      describe '#not_match_matcher' do
        it 'does not match a positive glob' do
          hostinfo = { role: 'test-app' }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.not_match_matcher('role' => 'test-*')).to be false
        end

        it 'does not match a positive exact match' do
          hostinfo = { role: 'test-app' }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.not_match_matcher('role' => 'test-app')).to be false
        end

        it 'does not match multiple positive matches' do
          hostinfo = { role: 'test-app', region: 'a' }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.not_match_matcher('role' => 'test-*', 'region' => 'a')).to be false
        end

        it 'match when negative match' do
          hostinfo = { role: 'test' }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.not_match_matcher('role' => 'test-app')).to be true
        end

        it 'match when one of multiple matches is missing from hostinfo' do
          hostinfo = { role: 'test-app' }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.not_match_matcher('role' => 'test-*', 'region' => 'a')).to be true
        end
      end

      describe '#including_matcher' do
        it 'match a positive include' do
          hostinfo = { role: 'test-app' }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.including_matcher('role' => ['test-app'])).to be true
        end

        it 'match when multiple positive includes' do
          hostinfo = { role: 'test-app',  region: 'a' }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.including_matcher('role' => ['test-app'], 'region' => 'a')).to be true
        end

        it 'does not match negative include' do
          hostinfo = { role: 'test-app' }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.including_matcher('role' => ['test'])).to be false
        end

        it 'does not match when one of multiple includes is missing from hostinfo' do
          hostinfo = { role: 'test-app' }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.including_matcher('role' => ['test-app'], 'region' => 'a')).to be false
        end
      end

      describe '#not_including_matcher' do
        it 'match when negative includes' do
          hostinfo = { role: 'test-app' }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.excluding_matcher('role' => ['test'])).to be true
        end

        it 'match when one of multiple includes is missing from hostinfo' do
          hostinfo = { role: 'test' }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.excluding_matcher('role' => ['test'], 'region' => 'a')).to be true
        end

        it 'does not match positive includes' do
          hostinfo = { role: 'test-app' }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.excluding_matcher('role' => ['test-app'])).to be false
        end

        it 'does not match when multiple positive includes' do
          hostinfo = { role: 'test-app',  region: 'a' }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.excluding_matcher('role' => ['test-app'], 'region' => 'a')).to be false
        end
      end

      describe '#applies?' do
        it 'returns true when there are no scope options' do
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.applies?({})).to be true
        end

        it 'runs the approprate matcher' do
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert).to receive(:match_matcher).once
          alert.applies?(
            'matches' => { 'application_name' => 'Sample App' }
          )
        end

        it 'runs the approprate matchers' do
          hostinfo = {
            source: 'new_relic_application',
            application_name: 'Sample App',
          }
          alert = @alert_yml.evaluate(hostinfo)
          allow(alert).to receive(:match_matcher).once.and_return(true)
          expect(alert).to receive(:including_matcher).once
          alert.applies?(
            'matches' => { 'application_name' => 'Sample App' },
            'including' => { 'application_name' => ['Sample App'] }
          )
        end
      end

      describe '#applies' do
        it 'return false if source does not match' do
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.applies).to be false
        end

        it 'return true if source and application matches' do
          hostinfo = {
            source: 'new_relic_application',
            application_name: 'Sample App',
          }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.applies).to be true
        end

        it 'return false if source matches and application does not match' do
          hostinfo = {
            source: 'new_relic_application',
            application_name: 'Sample Application',
          }
          alert = @alert_yml.evaluate(hostinfo)
          expect(alert.applies).to be false
        end
      end
    end
  end
end
