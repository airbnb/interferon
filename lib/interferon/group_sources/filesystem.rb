include ::Interferon::Logging

module Interferon::GroupSources
  class Filesystem
    def initialize(options)
      raise ArgumentError, 'missing paths for loading groups from filesystem' \
        unless options['paths']

      @paths = options['paths']
    end

    def list_groups
      groups = {}
      aliases = {}

      @paths.each do |path|
        path = File.expand_path(path)
        unless Dir.exist?(path)
          log.warn("no such directory #{path} for reading group files")
          next
        end

        Dir.glob(File.join(path, '*.{json,yml,yaml}')).each do |group_file|
          begin
            group = YAML.parse(File.read(group_file))
          rescue YAML::SyntaxError => e
            log.error("syntax error in group file #{group_file}: #{e}")
          rescue StandardError => e
            log.warn("error reading group file #{group_file}: #{e}")
          else
            group = group.to_ruby
            if group['people']
              groups[group['name']] = group['people'] || []
            elsif group['alias_for']
              aliases[group['name']] = { group: group['alias_for'], group_file: group_file }
            end
          end
        end
      end

      aliases.each do |aliased_group, group_info|
        group = group_info[:group]
        group_file = group_info[:group_file]
        if groups.include?(group)
          groups[aliased_group] = groups[group]
        else
          log.warn("Alias not found for #{group} but used by #{aliased_group} in #{group_file}")
        end
      end

      groups
    end
  end
end
