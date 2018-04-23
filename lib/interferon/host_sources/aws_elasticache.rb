require 'aws'

module Interferon::HostSources
  class AwsElasticache
    def initialize(options)
      missing = %w[access_key_id secret_access_key].reject { |r| options.key?(r) }

      AWS.config(access_key_id: options['access_key_id'],
                 secret_access_key: options['secret_access_key']) if missing.empty?

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
        clusters = []
        client = AWS::ElastiCache.new(region: region).client

        AWS.memoize do
          # read the list of cache clusters; we have to do our own pagination
          clusters = []
          options = { show_cache_node_info: true }
          loop do
            r = client.describe_cache_clusters(options)
            clusters += r.data[:cache_clusters]

            break unless r.data[:marker]
            options[:marker] = r.data[:marker]
          end

          # iterate over the nodes in each cluster and add each one to hosts
          clusters.each do |cluster|
            cluster[:cache_nodes].each do |node|
              hosts << {
                source: 'aws_elasticache',
                region: region,

                cluster_id: cluster[:cache_cluster_id],
                cluster_status: cluster[:cache_cluster_status],
                node_type: cluster[:cache_node_type],
                peer_nodes: cluster[:num_cache_nodes],

                node_status: node[:cache_node_status],

                # elasticache does not support tagging
                owners: [],
                owner_groups: [],
              }
            end
          end
        end
      end

      hosts
    end
  end
end
