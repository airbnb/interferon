module Interferon
  class Alert
    def initialize(alerts_repo_path, alert_path)
      @path = alert_path
      @filename = self.class.get_name_from_path(alerts_repo_path, alert_path)

      @text = File.read(@path)

      @dsl = nil
    end

    def to_s
      @filename
    end

    def evaluate(hostinfo)
      dsl = AlertDSL.new(hostinfo)
      dsl.instance_eval(@text, @filename, 1)
      @dsl = dsl

      # return the alert and not the DSL object, which is private
      self
    end

    def change_name(name)
      unless @dsl
        raise "This alert has not yet been evaluated"
      end

      @dsl.name(name)
    end

    def [](attr)
      unless @dsl
        raise "This alert has not yet been evaluated"
      end

      return @dsl.send(attr)
    end

    private

    def self.get_name_from_path(alerts_repo_path, alert_path)
      base_index = File.join(alerts_repo_path, 'alerts').split(File::SEPARATOR).length
      alert_path.split(File::SEPARATOR)[base_index..-1].join(File::SEPARATOR)
    end
  end
end
