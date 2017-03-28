module Interferon
  class Alert
    def initialize(path)
      @path = path
      @filename = File.basename(path)

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

    def silence
      unless @dsl
        raise "This alert has not yet been evaluated"
      end

      @dsl.silenced(true)
    end

    def [](attr)
      unless @dsl
        raise "This alert has not yet been evaluated"
      end

      return @dsl.send(attr)
    end
  end
end
