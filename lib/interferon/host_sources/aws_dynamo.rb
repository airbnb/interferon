require 'aws'

module Interferon::HostSources
  class AwsDynamo
    def initialize(options)
      missing = %w{access_key_id secret_access_key}.reject{|r| options.key?(r)}
      raise ArgumentError, "missing these required arguments for source AwsDynamo: #{missing.inspect}"\
        unless missing.empty?

      @access_key_id = options['access_key_id']
      @secret_access_key = options['secret_access_key']

      # initialize a list of regions to check
      if options['regions'] && !options['regions'].empty?
        @regions = options['regions']
      else
        @regions = AWS::regions.map(&:name)
      end
    end

    def list_hosts
      hosts = []

      @regions.each do |region|
        client = AWS::DynamoDB.new(
          :access_key_id => @access_key_id,
          :secret_access_key => @secret_access_key,
          :region => region)

        AWS.memoize do
          client.tables.each do |table|
            hosts << {
              :source => 'aws_dynamo',
              :region => region,
              :table_name => table.name,

              :read_capacity => table.read_capacity_units,
              :write_capacity => table.write_capacity_units,

              # dynamodb does not support tagging
              :owners => [],
              :owner_groups => [],
            }
          end
        end
      end

      return hosts
    end
  end
end
