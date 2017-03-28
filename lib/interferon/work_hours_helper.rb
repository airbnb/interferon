require 'tzinfo'

module Interferon
  class WorkHoursHelper
    DEFAULT_WORK_DAYS = (1..5)
    DEFAULT_WORK_HOURS = (9..16)
    DEFAULT_WORK_TIMEZONE = 'America/Los_Angeles'
    DEFAULT_WORK_ARGS = {
      :hours => DEFAULT_WORK_HOURS,
      :days => DEFAULT_WORK_DAYS,
      :timezone => DEFAULT_WORK_TIMEZONE,
    }.freeze

    def self.is_work_hour?(time, args = {})
      args = args.merge(DEFAULT_WORK_ARGS)
      tz = TZInfo::Timezone.get args[:timezone]
      time_in_tz = time + tz.period_for_utc(time).utc_offset
      return args[:days].include?(time_in_tz.wday) && args[:hours].include?(time_in_tz.hour)
    end
  end
end
