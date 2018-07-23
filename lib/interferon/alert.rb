# frozen_string_literal: true

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
      return self if @dsl && @dsl.applies == :once
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

    def [](attr)
      raise 'This alert has not yet been evaluated' unless @dsl

      @dsl.send(attr)
    end
  end
end
