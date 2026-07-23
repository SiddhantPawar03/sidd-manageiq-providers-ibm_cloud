module ManageIQ::Providers::IbmCloud::PowerVirtualServers::CloudManager::Provision::StateMachine
  def create_destination
    case request_type
    when 'clone_to_template'
      options[:destination] = 'image-catalog'
      signal :prepare_provision
    else
      signal :prepare_volumes_and_networks
    end
  end

  def prepare_volumes_and_networks
    new_volumes = options[:new_volumes]
    pass = get_option(:pass)
    phase_context[:new_volumes] = []

    if new_volumes.any?
      source.with_provider_connection(:service => "PCloudVolumesApi") do |api|
        new_volumes.each_with_index do |new_volume, idx|
          # Build a zero-padded 3-digit sequential name so volumes are clearly
          # identifiable in the PowerVS console.
          # Pattern: "<user-base><NNN>" e.g. "datavol001", "datavol002"
          # The counter combines vol-index and pass to stay unique across
          # multiple VMs in the same provisioning request.
          seq = format("%03d", (pass.to_i - 1) * new_volumes.size + idx + 1)
          volume_payload = new_volume.merge(:name => "#{new_volume[:name]}#{seq}")
          created_volume = api.pcloud_cloudinstances_volumes_post(
            cloud_instance_id, IbmCloudPower::CreateDataVolume.new(volume_payload)
          )
          phase_context[:new_volumes] << created_volume.volume_id
        end
      end
    end

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
