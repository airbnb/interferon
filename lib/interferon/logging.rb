require 'logger'
require 'statsd'

module Interferon
  module Logging

    def statsd
      @statsd ||= Statsd.new(
        Statsd::DEFAULT_HOST,
        Statsd::DEFAULT_PORT,
        :namespace => 'alerts_framework'
      )
    end

    def log
      @logger ||= Logging.configure_logger_for(self.class.name)
    end

    def self.configure_logger_for(classname)
      logger = Logger.new(STDERR)
      logger.level = Logger::INFO unless ENV['DEBUG']
      logger.progname = classname
      return logger
    end
  end
end
