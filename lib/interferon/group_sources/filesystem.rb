
module Interferon::GroupSources
  class Filesystem
    def initialize(options)
      raise ArgumentError, "missing paths for loading groups from filesystem" \
        unless options['paths']

      @paths = options['paths']
    end

    def list_groups
      groups = {}

      @paths.each do |path|
        path = File.expand_path(path)
        unless Dir.exists?(path)
          log.warn "no such directory #{path} for reading group files"
          next
        end

        Dir.glob(File.join(path, '*.{json,yml,yaml}')) do |group_file|
          begin
            group = YAML::parse(File.read(group_file))
          rescue YAML::SyntaxError => e
            log.error "syntax error in group file #{group_file}: #{e}"
          rescue StandardError => e
            log.warn "error reading group file #{group_file}: #{e}"
          else
            group = group.to_ruby
            groups[group['name']] = group['people'] || []
          end
        end
      end

      return groups
    end
  end
end
