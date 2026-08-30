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

  # Override the core cloud state machine's poll_clone_complete to handle the
  # case where make_request_clone returned an array of pvm_instance_ids
  # (replicants > 1).  For a single VM the behaviour is identical to core.
  def poll_clone_complete
    clone_status, status_message = do_clone_task_check(phase_context[:clone_task_ref])

    status_message = "completed; post provision work queued" if clone_status
    message = "Clone of #{clone_direction} is #{status_message}"
    _log.info(message)
    update_and_notify_parent(:message => message)

    if clone_status
      clone_task_ref = phase_context.delete(:clone_task_ref)
      ids = Array(clone_task_ref)

      # Store the first ID as new_vm_ems_ref so the core poll_destination_in_vmdb
      # machinery can locate the destination VM after inventory refresh lands.
      phase_context[:new_vm_ems_ref] = ids.first

      manager = source.ext_management_system

      if manager.allow_targeted_refresh?
        target_collection = InventoryRefresh::TargetCollection.new(:manager => manager)
        ids.each { |id| target_collection.add_target(:association => :vms, :manager_ref => {:ems_ref => id}) }
        EmsRefresh.queue_refresh(target_collection)
      else
        EmsRefresh.queue_refresh(manager)
      end

      if options[:new_volumes].present?
        signal :attach_affinity_volumes
      else
        signal :poll_destination_in_vmdb
      end
    else
      requeue_phase
    end
  end

  def attach_affinity_volumes
    active_instances = phase_context.delete(:active_instances) || []
    ids = active_instances.map { |e| e[:id] }

    active_instances.each_with_index do |entry, idx|
      create_and_attach_affinity_volumes(entry[:id], entry[:server_name], idx + 1)
    end

    message = "Affinity volumes created and attached for #{ids.length} instance(s)."
    _log.info(message)
    update_and_notify_parent(:message => message)

    signal :poll_destination_in_vmdb
  end

  def prepare_volumes_and_networks
    # New volumes require affinity to the VM's boot volume storage pool,
    # which is only known after the VM is created and ACTIVE.
    # They are created and attached in the attach_affinity_volumes state
    # after all instances reach ACTIVE_READY.
    phase_context[:new_volumes] = []

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
