# frozen_string_literal: true

require 'aws'

module Interferon::HostSources
  class AwsDynamo
    def initialize(options)
      missing = %w[access_key_id secret_access_key].reject { |r| options.key?(r) }

      if missing.empty?
        AWS.config(access_key_id: options['access_key_id'],
                   secret_access_key: options['secret_access_key'])
      end

      # initialize a list of regions to check
      @regions = if options['regions'] && !options['regions'].empty?
                   options['regions']
                 else
                   AWS.regions.map(&:name)
                 end
    end

    def list_hosts
      hosts = []

      @regions.each do |region|
        client = AWS::DynamoDB.new(region: region)

        AWS.memoize do
          client.tables.each do |table|
            hosts << {
              source: 'aws_dynamo',
              region: region,
              table_name: table.name,

              read_capacity: table.read_capacity_units,
              write_capacity: table.write_capacity_units,

              # dynamodb does not support tagging
              owners: [],
              owner_groups: [],
            }
          end
        end
      end

      hosts
    end
  end
end
