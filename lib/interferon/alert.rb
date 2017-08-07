module Interferon
  attr_accessor :counters

  class Alert
    def initialize(path)
      @path = path
      @filename = File.basename(path)

      @text = File.read(@path)
      @counters = Hash.new(0)

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
