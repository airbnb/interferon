class OpticaHelper
  def self.example_node_1
    {
      'ip' => '10.1.1.1',
      'environment' => 'production',
      'role' => 'role1',
      'hostname' => 'box1',
      'uptime' => 37_335_310,
      'az' => 'us-east-1a',
      'security_groups' => ['internal'],
      'instance_type' => 'm1.large',
      'ami_id' => 'ami-d9d6a6b0',
      'failed' => false,
      'roles' => ['role1'],
      'recipes' => ['airbnb-base', 'cookbook1'],
      'synapse_services' => %w(service1 service2),
      'nerve_services' => [],
      'ownership' => {
        'people' => ['test_user@example.com'],
        'groups' => ['admins'],
      },
      'converger' => 'ben_hughes',
    }
  end

  def self.example_node_2
    {
      'ip' => '10.1.1.2',
      'environment' => 'production',
      'role' => 'role2',
      'hostname' => 'box2',
      'uptime' => 37_335_310,
      'az' => 'us-east-1b',
      'security_groups' => ['internal'],
      'instance_type' => 'm1.large',
      'ami_id' => 'ami-d9d6a6b0',
      'failed' => false,
      'roles' => ['role2'],
      'recipes' => ['airbnb-base', 'cookbook2'],
      'synapse_services' => [],
      'nerve_services' => ['service1'],
      'ownership' => {
        'people' => ['test_user@example.com'],
        'groups' => ['admins'],
      },
      'converger' => 'ben_hughes',
    }
  end

  def self.example_node_3
    {
      'ip' => '10.1.1.3',
      'environment' => 'production',
      'role' => 'role3',
      'hostname' => 'box3',
      'uptime' => 37_335_310,
      'az' => 'us-east-1b',
      'security_groups' => ['internal'],
      'instance_type' => 'm1.large',
      'ami_id' => 'ami-d9d6a6b0',
      'failed' => false,
      'roles' => ['role3'],
      'recipes' => ['airbnb-base', 'cookbook3'],
      'synapse_services' => [],
      'nerve_services' => ['service2'],
      'converger' => 'ben_hughes',
    }
  end

  def self.example_node_4
    {
      'ip' => '10.1.1.4',
      'environment' => 'production',
      'role' => 'role4',
      'hostname' => 'box4',
      'uptime' => 37_335_310,
      'az' => 'us-east-1e',
      'security_groups' => ['internal'],
      'instance_type' => 'm1.large',
      'ami_id' => 'ami-d9d6a6b0',
      'failed' => false,
      'roles' => ['role4'],
      'recipes' => ['airbnb-base', 'cookbook4'],
      'synapse_services' => [],
      'nerve_services' => ['service1'],
      'ownership' => {
        'people' => ['test_user2@example.com'],
        'groups' => ['engineers'],
      },
      'converger' => 'ben_hughes',
    }
  end

  def self.example_nodes
    {
      example_node_1['ip'] => example_node_1,
      example_node_2['ip'] => example_node_2,
      example_node_3['ip'] => example_node_3,
      example_node_4['ip'] => example_node_4,
    }
  end

  def self.example_output
    {
      'examined' => 3,
      'returned' => 3,
      'nodes' => example_nodes,
    }
  end
end
