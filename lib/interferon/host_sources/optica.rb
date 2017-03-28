require 'net/http'
require 'json'

module Interferon::HostSources
  class Optica
    include ::Interferon::Logging

    def initialize(options)
      raise ArgumentError, "missing host for optica source" \
        unless options['host']

      @host = options['host']
      @port = options['port'] || 80
    end

    def list_hosts
      return optica_data['nodes'].map{|ip, host| {
          :source => 'optica',
          :hostname => host['hostname'],
          :role => host['role'],
          :environment => host['environment'],

          :owners => host['ownership'] && host['ownership']['people'] || [],
          :owner_groups => host['ownership'] && host['ownership']['groups'] || [],
        }}
    end

    def optica_data
      @optica_data ||= begin
        con = Net::HTTP.new(@host, @port)
        con.read_timeout = 60
        con.open_timeout = 60

        response = con.get('/')
        JSON::parse(response.body)
      end
    end
  end
end
