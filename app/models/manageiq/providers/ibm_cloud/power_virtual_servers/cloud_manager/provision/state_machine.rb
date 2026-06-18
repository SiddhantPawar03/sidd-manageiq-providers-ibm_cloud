module ManageIQ::Providers::IbmCloud::PowerVirtualServers::CloudManager::Provision::StateMachine
  def create_destination
    case request_type
    when 'clone_to_template'
      options[:destination] = 'image-catalog'
      signal :prepare_provision
    else
      signal :prepare_networks
    end
  end

  def prepare_networks
    phase_context[:new_networks] = []

    if options[:public_network][0]
      source.with_provider_connection(:service => "PCloudNetworksApi") do |api|
        new_network_params = IbmCloudPower::NetworkCreate.new(:type => "pub-vlan")
        new_network = api.pcloud_networks_post(cloud_instance_id, new_network_params)
        phase_context[:new_networks] << {"networkID" => new_network.network_id}
      end
    end

    signal :prepare_provision
  end
end
