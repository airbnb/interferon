# disable logging during spec runs
module Interferon::Logging
  class EmptyLogger < StringIO
    def write(input)
      # do nothing
    end
  end

  def self.configure_logger_for(_clasname)
    Logger.new(EmptyLogger.new)
  end
end
