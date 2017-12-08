# frozen_string_literal: true

require 'aws'

module Interferon::HostSources
  class AwsRds
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
        rds = AWS::RDS.new(region: region)

        AWS.memoize do
          rds.instances.each do |instance|
            # get the tags for the instance
            arn = arn(region, instance.id)
            tag_list = rds.client.list_tags_for_resource(resource_name: arn)[:tag_list]
            tags = Hash[tag_list.map { |h| [h[:key], h[:value]] }]

            tags['owners'] ||= ''
            tags['owner_groups'] ||= ''

            # build the host data for this instance
            hosts << {
              source: 'aws_rds',
              region: region,
              instance_id: instance.id,
              db_name: instance.db_name,
              engine: instance.engine,
              engine_version: instance.engine_version,

              # metrics
              allocated_storage: instance.allocated_storage,
              iops: instance.iops,

              # replication info
              is_replica: !instance.read_replica_source_db_instance_identifier.nil?,
              replica_source_name: instance.read_replica_source_db_instance_identifier,
              replica_names: instance.read_replica_db_instance_identifiers.join(','),
              replicas: instance.read_replica_db_instance_identifiers.count,

              owners: tags['owners'].split(','),
              owner_groups: tags['owner_groups'].split(','),

              db_env: tags['db_env'],
              db_role: tags['db_role'],
            }
          end
        end
      end

      hosts
    end

    private

    def arn(region, instance_id)
      "arn:aws:rds:#{region}:#{account_number}:db:#{instance_id}"
    end

    # unfortunately, this appears to be the only way to get your account number
    def account_number
      return @account_number if @account_number

      begin
        my_arn = AWS::IAM.new(
          access_key_id: @access_key_id,
          secret_access_key: @secret_access_key
        ).client.get_user[:user][:arn]
      rescue AWS::IAM::Errors::AccessDenied => e
        my_arn = e.message.split[1]
      end

      @account_number = my_arn.split(':')[4]
    end
  end
end
