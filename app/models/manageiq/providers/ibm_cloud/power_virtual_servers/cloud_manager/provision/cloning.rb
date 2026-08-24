module ManageIQ::Providers::IbmCloud::PowerVirtualServers::CloudManager::Provision::Cloning
  def log_clone_options(clone_options)
    _log.info('IBM SERVER PROVISIONING OPTIONS: ' + clone_options.to_s)
  end

  def prepare_for_clone_task
    _log.info("#{self.class}##{__method__} request_type=#{request_type}")
    request_type == 'clone_to_template' ? prepare_for_clone_to_template : prepare_for_clone
  end

  def start_clone(clone_options)
    _log.info("#{self.class}##{__method__} request_type=#{request_type}")
    if request_type == 'clone_to_template'
      make_request_clone_to_template(clone_options)
    elsif sap_image?
      make_request_clone_sap_vm(clone_options)
    else
      make_request_clone(clone_options)
    end
  rescue IbmCloudPower::ApiError => err
    error_message = JSON.parse(err.response_body)["description"] || err.message
    _log.error("VM start_clone error: #{error_message}")
    raise MiqException::MiqProvisionError, error_message
  end

  def do_clone_task_check(clone_task_ref)
    _log.info("#{self.class}##{__method__} clone_task_ref=#{clone_task_ref}")
    request_type == 'clone_to_template' ? check_task_clone_to_template(clone_task_ref) : check_task_clone(clone_task_ref)
  end

  def customize_destination
    signal :post_create_destination
  end

  def find_destination_in_vmdb(ems_ref)
    return if phase_context[:cloud_api_completion_time].nil? || source.ext_management_system.last_refresh_date < phase_context[:cloud_api_completion_time]

    if request_type == 'clone_to_template'
      # ems_ref is actually a Job ID
      source.ext_management_system&.vms_and_templates&.find_by(:name => options[:vm_name], :template => true)
    else
      source.ext_management_system&.vms_and_templates&.find_by(:ems_ref => ems_ref, :template => false)
    end
  end

  private

  def prepare_for_clone_to_template
    {
      'capture_name'        => get_option(:vm_target_name),
      'capture_destination' => get_option(:destination),
    }
  end

  def prepare_for_clone
    specs = {
      'image_id'   => get_option_last(:src_vm_id),
      'pin_policy' => get_option_last(:pin_policy),
    }

    chosen_key_pair = get_option_last(:guest_access_key_pair)

    if sap_image?
      specs['name']         = get_option(:vm_target_name)
      specs['profile_id']   = get_option_last(:sys_type)
      specs['ssh_key_name'] = chosen_key_pair unless chosen_key_pair == 'None'
    else
      specs['server_name']   = get_option(:vm_target_name)
      specs['memory']        = get_option_last(:vm_memory).to_i
      specs['processors']    = get_option_last(:entitled_processors).to_f
      specs['proc_type']     = get_option_last(:instance_type)
      specs['pin_policy']    = get_option_last(:pin_policy)
      specs['replicants']    = 1 # TODO: we have to use this field instead of what 'MIQ' does
      specs['key_pair_name'] = chosen_key_pair unless chosen_key_pair == 'None'
      specs['storage_type']  = get_option_last(:storage_type)
      specs['sys_type']      = get_option_last(:sys_type)
    end

    specs['placement_group'] = get_option(:placement_group) unless get_option(:placement_group).nil?
    specs['shared_processor_pool'] = get_option(:shared_processor_pool) unless get_option(:shared_processor_pool).nil?
    user_script_text = options[:user_script_text]
    user_script_text64 = Base64.encode64(user_script_text) unless user_script_text.nil?
    specs['user_data'] = user_script_text64 unless user_script_text64.nil?

    attached_volumes = options[:cloud_volumes] || []
    specs['volume_ids'] = attached_volumes unless attached_volumes.empty?

    attached_networks = case get_option(:vlan)
                        when 'None'
                          []
                        else
                          [{"networkID" => get_option(:vlan)}] # TODO: support multiple values
                        end
    attached_networks.concat(phase_context[:new_networks]).compact!
    specs['networks'] = attached_networks

    # TODO: support multiple values
    ip_addr = get_option_last(:ip_addr)
    specs['networks'][0]['ipAddress'] = ip_addr if ip_addr.present?

    specs
  end

  def make_request_clone_to_template(clone_options)
    source.with_provider_connection(:service => "PCloudPVMInstancesApi") do |api|
      vm = Vm.find(get_option(:src_vm_id))
      body = IbmCloudPower::PVMInstanceCapture.new(clone_options)
      _log.info("#{self.class}##{__method__} capturing VM #{vm.uid_ems} as template")
      response = api.pcloud_v2_pvminstances_capture_post(cloud_instance_id, vm.uid_ems, body)
      _log.info("#{self.class}##{__method__} capture job id=#{response.id}")
      response.id
    end
  end

  def make_request_clone_sap_vm(clone_options)
    source.with_provider_connection(:service => "PCloudSAPApi") do |api|
      body = IbmCloudPower::SAPCreate.new(clone_options)
      _log.info("#{self.class}##{__method__} creating SAP VM")
      response = api.pcloud_sap_post(cloud_instance_id, body)
      pvm_instance_id = response&.first&.pvm_instance_id
      _log.info("#{self.class}##{__method__} SAP VM pvm_instance_id=#{pvm_instance_id}")
      pvm_instance_id
    end
  end

  def make_request_clone(clone_options)
    source.with_provider_connection(:service => "PCloudPVMInstancesApi") do |api|
      body = IbmCloudPower::PVMInstanceCreate.new(clone_options)
      _log.info("#{self.class}##{__method__} creating VM with options=#{clone_options}")
      response = api.pcloud_pvminstances_post(cloud_instance_id, body)
      pvm_instance_id = response&.first&.pvm_instance_id
      _log.info("#{self.class}##{__method__} created VM pvm_instance_id=#{pvm_instance_id}")
      pvm_instance_id
    end
  end

  def check_task_clone_to_template(clone_task_ref)
    source.with_provider_connection(:service => 'PCloudJobsApi') do |api|
      job = api.pcloud_cloudinstances_jobs_get(source.ext_management_system.uid_ems, clone_task_ref)
      stop = (job.status.state == 'completed')
      phase_context[:cloud_api_completion_time] = Time.zone.now.utc if stop
      status = job.status.message.nil? ? job.status.state : "#{job.status.state} Message: '#{job.status.message}'"
      return stop, status
    end
  end

  def check_task_clone(clone_task_ref)
    source.with_provider_connection(:service => "PCloudPVMInstancesApi") do |api|
      instance = api.pcloud_pvminstances_get(cloud_instance_id, clone_task_ref)
      instance_state = instance.status
      stop = false

      _log.info("#{self.class}##{__method__} VM #{clone_task_ref} state=#{instance_state}")

      case instance_state
      when 'BUILD'
        status = 'The server is being provisioned.'
      when 'ACTIVE'
        _log.info("#{self.class}##{__method__} VM #{clone_task_ref} ACTIVE new_volumes=#{options[:new_volumes]&.size} attachment_complete=#{options[:new_volume_attachment_complete]}")
        if options[:new_volume_attachment_complete] || options[:new_volumes].blank?
          # Either volumes already attached, or no new volumes were requested.
          stop = (instance.processors.to_f > 0) && (instance.memory.to_f > 0)
          phase_context[:cloud_api_completion_time] = Time.zone.now.utc if stop
          _log.info("#{self.class}##{__method__} VM #{clone_task_ref} processors=#{instance.processors} memory=#{instance.memory} stop=#{stop}")
          status = "The server has been provisioned.; #{stop ? 'Server description available.' : 'Waiting for server description.'}"
        else
          _log.info("#{self.class}##{__method__} VM #{clone_task_ref} ACTIVE - attaching affinity volumes")
          create_and_attach_affinity_volumes(clone_task_ref, instance.server_name)
          options[:new_volume_attachment_complete] = true
          status = 'The server has been provisioned. Affinity volumes created and attached.'
        end
      when 'ERROR'
        _log.error("#{self.class}##{__method__} VM #{clone_task_ref} entered ERROR state")
        raise MiqException::MiqProvisionError, _("An error occurred while provisioning the instance.")
      else
        status = "Unknown server state received from the cloud API: '#{instance_state}'"
        _log.warn(status)
      end

      return stop, status
    end
  rescue IbmCloudPower::ApiError => err
    # Handle HTTP 500 errors during VM initialization (e.g., BDM attachment in progress)
    if err.code.to_i == 500 && err.response_body.to_s.include?("in process of bdm attachment")
      _log.info("VM is still initializing (attaching block devices), will retry")
      return false, "VM initializing, attaching storage..."
    else
      raise
    end
  end

  def create_and_attach_affinity_volumes(vm_ems_ref, vm_instance_name)
    new_volumes = options[:new_volumes] || []
    _log.info("#{self.class}##{__method__} VM #{vm_ems_ref} new_volumes count=#{new_volumes.size}")
    return if new_volumes.empty?

    phase_context[:new_volumes] ||= []
    pass      = get_option(:pass).to_i
    pass      = 1 if pass < 1
    # :total_vms is a plain integer stored by set_request_values before
    # :number_of_vms is clamped — so get_option always returns it reliably.
    total_vms = get_option(:total_vms).to_i
    total_vms = 1 if total_vms < 1
    multi_vm  = pass > 1 || total_vms > 1

    _log.info("#{self.class}##{__method__} pass=#{pass} total_vms=#{total_vms} multi_vm=#{multi_vm}")

    source.with_provider_connection(:service => "PCloudVolumesApi") do |api|
      new_volumes.each_with_index do |new_volume, idx|
        # Single-instance: keep base name as-is (e.g. "spVol").
        # Multi-instance: append zero-padded suffix per VM so names are
        # unique across tasks: spVol001 (pass=1), spVol002 (pass=2), etc.
        vol_name = if multi_vm
                     seq = "%03d" % (((pass - 1) * new_volumes.size) + idx + 1)
                     "#{new_volume[:name]}#{seq}"
                   else
                     new_volume[:name]
                   end
        _log.info("#{self.class}##{__method__} creating affinity volume '#{vol_name}' (pass=#{pass}, total_vms=#{total_vms}) for VM #{vm_ems_ref}")
        volume_params = new_volume.merge(
          :name                  => vol_name,
          :affinity_policy       => "affinity",
          :affinity_pvm_instance => vm_instance_name
        )

        created_volume = api.pcloud_cloudinstances_volumes_post(
          cloud_instance_id,
          IbmCloudPower::CreateDataVolume.new(volume_params)
        )

        _log.info("#{self.class}##{__method__} created volume id=#{created_volume.volume_id} name='#{vol_name}'")
        begin
          api.pcloud_pvminstances_volumes_post(cloud_instance_id, vm_ems_ref, created_volume.volume_id)
          phase_context[:new_volumes] << created_volume.volume_id
          _log.info("#{self.class}##{__method__} attached volume #{created_volume.volume_id} to VM #{vm_ems_ref}")
        rescue IbmCloudPower::ApiError => e
          _log.warn("#{self.class}##{__method__} failed to attach volume #{created_volume.volume_id} to #{vm_ems_ref} (#{e.message}), deleting orphaned volume")
          api.pcloud_cloudinstances_volumes_delete(cloud_instance_id, created_volume.volume_id)
          raise
        end
      end
    end
  end
end
