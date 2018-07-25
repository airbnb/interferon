# frozen_string_literal: true

require 'spec_helper'
require 'interferon/work_hours_helper'

describe Interferon::WorkHoursHelper do
  subject { described_class }

  describe '.now_is_work_hour?' do
    context 'when it is a work hour in a work day' do
      it 'return true' do
        expect(subject.is_work_hour?(
                 Time.parse('Mon Nov 26 9:01:20 PST 2001').utc
               )).to be_truthy
        expect(subject.is_work_hour?(
                 Time.parse('Fri Nov 30 16:35:20 PST 2001').utc
               )).to be_truthy
      end
    end

    context 'when it is a work hour in a weekend' do
      it 'return false' do
        expect(subject.is_work_hour?(
                 Time.parse('Sat Nov 24 09:01:20 PST 2001').utc
               )).to be_falsy
        expect(subject.is_work_hour?(
                 Time.parse('Sun Nov 25 09:01:20 PST 2001').utc
               )).to be_falsy
      end
    end

    context 'when it is not a work hour' do
      it 'return false' do
        expect(subject.is_work_hour?(
                 Time.parse('Thu Nov 29 08:33:20 PST 2001').utc
               )).to be_falsy
        expect(subject.is_work_hour?(
                 Time.parse('Fri Nov 30 17:33:20 PST 2001').utc
               )).to be_falsy
      end
    end
  end
end
