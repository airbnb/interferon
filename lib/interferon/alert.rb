module Interferon
  class Alert
    def initialize(path, alert_file)
      @path = alert_file.clone
      alert_file.slice! path
      @filename = alert_file

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
      raise 'This alert has not yet been evaluated' unless @dsl

      @dsl.name(name)
    end

    def silence
      raise 'This alert has not yet been evaluated' unless @dsl

      @dsl.silenced(true)
    end

    def [](attr)
      raise 'This alert has not yet been evaluated' unless @dsl

      @dsl.send(attr)
    end
  end
end
