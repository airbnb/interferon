# frozen_string_literal: true

module Interferon
  class AlertYaml < Alert
    def initialize(alert_repo_path, alert_file_path)
      super

      @data = nil
      @scope = nil
      @notify = nil
    end

    def to_s
      @filename
    end

    def evaluate(hostinfo)
      safe_hostinfo = Hash.new('').merge!(hostinfo)
      text = string_format(@text, safe_hostinfo)
      @data = YAML.safe_load(text)
      @scope = hostinfo

      @data['name'] += ' [Interferon]'

      @notify = {
        groups: [],
        people: [],
      }

      @data['options']['notifiers'].each do |notifier|
        args = notifier['args']
        case notifier['type']
        when 'groups'
          @notify[:groups].concat(args['groups'])
        when 'people'
          @notify[:people].concat(args['people'])
        end
      end
      # return the alert and not the DSL object, which is private
      self
    end

    def string_format(string, hash)
      missing_key_re = /key{(.+)} not found/
      begin
        string % hash
      rescue KeyError => e
        key_name = missing_key_re.match(e.message)[1]
        hash[key_name.to_sym] = ''
        retry
      end
    end

    def match_matcher(match_options)
      match_options.each do |key, value|
        scope_value = @scope[key.intern]
        return false unless scope_value && File.fnmatch(value, scope_value)
      end
      true
    end

    def not_match_matcher(match_options)
      !match_matcher(match_options)
    end

    def including_matcher(match_options)
      match_options.each do |key, value|
        scope_value = @scope[key.intern]
        return false unless scope_value && value.include?(scope_value)
      end
      true
    end

    def excluding_matcher(match_options)
      !including_matcher(match_options)
    end

    def applies?(scope_option)
      scope_option.each do |matcher, matcher_options|
        result = case matcher
                 when 'matches'
                   match_matcher(matcher_options)
                 when 'not_matches'
                   not_match_matcher(matcher_options)
                 when 'including'
                   including_matcher(matcher_options)
                 when 'excluding'
                   excluding_matcher(matcher_options)
                 end
        return false unless result
      end
      true
    end

    def applies
      return false unless @scope[:source] == @data['scope']
      @data['scope_options'].each do |scope_option|
        return true if applies?(scope_option)
      end
      false
    end

    def [](attr)
      raise 'This alert has not yet been evaluated' unless @data
      case attr
      when :applies, 'applies'
        applies
      when :notify, 'notify'
        @notify
      when :scope, 'scope'
        @scope
      else
        @data[attr.to_s]
      end
    end
  end
end
