# frozen_string_literal: true

module Interferon
  class Alert
    def initialize(alert_repo_path, alert_file_path, options = {})
      @path = alert_file_path
      @filename = alert_file_path.sub(/^#{File.join(alert_repo_path, '/')}/, '')

      @suffix = options[:suffix]
      @text = File.read(alert_file_path)

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

      # Add suffix to name
      change_name("#{@dsl.name} #{@suffix}") if @suffix

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
