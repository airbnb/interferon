
module Interferon

  # lets create namespaces for things we'll be loading
  module Destinations; end
  module HostSources; end
  module GroupSources; end

  # this is a type of class that can dynamically load other classes based on
  # a 'type' string
  class DynamicLoader
    include Logging

    def initialize(custom_paths)
      @paths = []
      custom_paths.each do |custom_path|
        @paths << File.expand_path(custom_path)
      end

      initialize_attributes
    end

    # this should be overridden in specific loaders
    def initialize_attributes
      @loader_for = 'class'
      @type_path  = ''
      @module     = ::Interferon
    end

    def get_all(sources)
      instances = []

      sources.each_with_index do |source, idx|
        type    =   source['type']
        enabled = !!source['enabled']
        options =   source['options'] || {}

        if type.nil?
          log.warn "#{@loader_for} ##{idx} does not have a 'type' set; 'type' is required"
          next
        end

        if !enabled
          log.info "skipping #{@loader_for} #{type} because it's not enabled"
          next
        end

        instance = get_klass(type).new(options)
        instances << instance
      end

      instances
    end

    def get_klass(type)
      # figure out what we're getting based on the type
      filename = type.downcase
      type_parts = filename.split('_')
      class_name = type_parts.map(&:capitalize).join

      # ideally, we'll put a constant into this variable
      klass = nil

      # first, try getting from custom paths
      @paths.each do |path|
        full_path = "#{path}/#{@type_path}/#{filename}"

        begin
          require full_path
          klass = @module.const_get(class_name)
        rescue LoadError => e
          log.debug "LoadError looking for #{@loader_for} file #{type} at #{full_path}: #{e}"
        rescue NameError => e
          log.debug "NameError looking for #{@loader_for} class #{class_name} in #{full_path}: #{e}"
        end

        break if klass
      end

      # if that doesn't work, try getting from this repo via require_relative
      if klass.nil?
        begin
          relative_filename = "./#{@type_path}/#{filename}"

          require_relative relative_filename
          klass = @module.const_get(class_name)
        rescue LoadError => e
          raise ArgumentError,\
            "Loading Error; interferon does not define #{@loader_for} #{type}: #{e}"
        rescue NameError => e
          raise ArgumentError,\
            "Name Error; class #{class_name} is not defined in #{relative_filename}: #{e}"
        end
      end

      return klass
    end
  end

  class DestinationsLoader < DynamicLoader
    def initialize_attributes
      @loader_for = 'destination'
      @type_path = 'destinations'
      @module = ::Interferon::Destinations
    end
  end

  class HostSourcesLoader < DynamicLoader
    def initialize_attributes
      @loader_for = 'host source'
      @type_path = 'host_sources'
      @module = ::Interferon::HostSources
    end
  end

  class GroupSourcesLoader < DynamicLoader
    def initialize_attributes
      @loader_for = 'group source'
      @type_path = 'group_sources'
      @module = ::Interferon::GroupSources
    end
  end
end
