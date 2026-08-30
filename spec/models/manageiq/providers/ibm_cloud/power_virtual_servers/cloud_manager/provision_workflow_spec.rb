describe ManageIQ::Providers::IbmCloud::PowerVirtualServers::CloudManager::ProvisionWorkflow do
  include Spec::Support::WorkflowHelper

  let(:admin) { FactoryBot.create(:user_with_group) }
  let(:ems) { FactoryBot.create(:ems_ibm_cloud_power_virtual_servers_cloud) }

  context "clone" do
    let(:template) do
      FactoryBot.create(
        :template_ibm_cloud_power_virtual_servers,
        :name                  => "template",
        :ext_management_system => ems
      )
    end
    let(:workflow) do
      stub_dialog
      allow(User).to receive_messages(:server_timezone => "UTC")
      described_class.new({:src_vm_id => template.id}, admin.userid)
    end

    it "#parse_new_volumes_fields" do
      values = {
        :storage_type => [0, "tier1"],
        :name         => nil,
        :size         => nil,
        :shareable    => false
      }
      expect(workflow.parse_new_volumes_fields(values))
        .to match_array([])
      values = {
        :storage_type => [1, "tier1"],
        :name         => nil,
        :size         => nil,
        :shareable    => false,
        :name_1       => "disk_one",
        :size_1       => "1",
        :shareable_1  => "null",
        :name_2       => "disk_two",
        :size_2       => "2",
        :name_3       => "disk_three",
        :size_3       => "3",
        :shareable_3  => nil,
        :name_4       => "disk_four",
        :size_4       => "4",
        :shareable_4  => true
      }
      expect(workflow.parse_new_volumes_fields(values))
        .to match_array(
          [
            {
              :name      => "disk_one",
              :size      => 1,
              :disk_type => "tier1",
              :shareable => false
            },
            {
              :name      => "disk_two",
              :size      => 2,
              :disk_type => "tier1",
              :shareable => false
            },
            {
              :name      => "disk_three",
              :size      => 3,
              :disk_type => "tier1",
              :shareable => false
            },
            {
              :name      => "disk_four",
              :size      => 4,
              :disk_type => "tier1",
              :shareable => true
            }
          ]
        )
      values = {
        :storage_type => [2, "tier1"],
        :name         => nil,
        :size         => nil,
        :shareable    => false,
        :name_1       => "disk_one",
        :shareable_1  => "null",
        :size_2       => "2",
        :name_3       => "disk_three",
        :size_3       => "3",
        :name_4       => "disk_four",
        :size_4       => "",
        :shareable_4  => true
      }
      expect(workflow.parse_new_volumes_fields(values))
        .to match_array(
          [
            {
              :name      => "disk_one",
              :disk_type => "tier1",
              :size      => 0,
              :shareable => false
            },
            {
              :name      => "vol",
              :size      => 2,
              :disk_type => "tier1",
              :shareable => false
            },
            {
              :name      => "disk_three",
              :size      => 3,
              :disk_type => "tier1",
              :shareable => false
            },
            {
              :name      => "disk_four",
              :size      => 0,
              :disk_type => "tier1",
              :shareable => true
            }
          ]
        )
    end

    it "#parse_new_volumes_fields defaults name to 'vol' when blank or missing" do
      values = {
        :storage_type => [1, "tier3"],
        :name_1       => "",
        :size_1       => "10",
        :name_2       => nil,
        :size_2       => "20",
        :name_3       => "mydata",
        :size_3       => "30"
      }
      expect(workflow.parse_new_volumes_fields(values))
        .to match_array(
          [
            {
              :name      => "vol",
              :size      => 10,
              :disk_type => "tier3",
              :shareable => false
            },
            {
              :name      => "vol",
              :size      => 20,
              :disk_type => "tier3",
              :shareable => false
            },
            {
              :name      => "mydata",
              :size      => 30,
              :disk_type => "tier3",
              :shareable => false
            }
          ]
        )
    end
  end

  context "cloning affinity volumes" do
    let(:cloning_class) do
      Class.new do
        include ManageIQ::Providers::IbmCloud::PowerVirtualServers::CloudManager::Provision::Cloning

        public :check_task_clone
        public :create_and_attach_affinity_volumes

        attr_accessor :options, :phase_context

        def initialize
          @options = {}
          @phase_context = {}
        end

        def source
          @source ||= Object.new
        end

        def cloud_instance_id
          "cloud-instance-id"
        end

        def get_option(key)
          options[key]
        end

        def _log
          @log ||= Logger.new(nil)
        end
      end
    end

    let(:state_machine_class) do
      Class.new do
        include ManageIQ::Providers::IbmCloud::PowerVirtualServers::CloudManager::Provision::Cloning
        include ManageIQ::Providers::IbmCloud::PowerVirtualServers::CloudManager::Provision::StateMachine

        public :attach_affinity_volumes

        attr_accessor :options, :phase_context

        def initialize
          @options = {}
          @phase_context = {}
        end

        def source
          @source ||= Object.new
        end

        def cloud_instance_id
          "cloud-instance-id"
        end

        def get_option(key)
          options[key]
        end

        def _log
          @log ||= Logger.new(nil)
        end

        def update_and_notify_parent(**_kwargs); end

        def signal(_state); end
      end
    end

    let(:provision) { cloning_class.new }
    let(:api) { instance_double("PCloudPVMInstancesApi") }
    let(:instance1) { double(:status => "ACTIVE", :processors => 1.0, :memory => 1024, :server_name => "vm1") }
    let(:instance2) { double(:status => "ACTIVE", :processors => 1.0, :memory => 1024, :server_name => "vm2") }

    it "returns true and stores active_instances in phase_context when all instances are ACTIVE_READY" do
      provision.options = {:new_volumes => [{:name => "data", :size => 10}]}
      allow(provision.source).to receive(:with_provider_connection).and_yield(api)
      allow(api).to receive(:pcloud_pvminstances_get).with("cloud-instance-id", "id-1").and_return(instance1)
      allow(api).to receive(:pcloud_pvminstances_get).with("cloud-instance-id", "id-2").and_return(instance2)

      complete, status = provision.check_task_clone(["id-1", "id-2"])

      expect(complete).to be(true)
      expect(status).to eq("All 2 instance(s) provisioned and active.")
      expect(provision.phase_context[:active_instances]).to eq(
        [{:id => "id-1", :server_name => "vm1"}, {:id => "id-2", :server_name => "vm2"}]
      )
    end

    it "does not call create_and_attach_affinity_volumes from check_task_clone" do
      provision.options = {:new_volumes => [{:name => "data", :size => 10}]}
      allow(provision.source).to receive(:with_provider_connection).and_yield(api)
      allow(api).to receive(:pcloud_pvminstances_get).with("cloud-instance-id", "id-1").and_return(instance1)
      allow(api).to receive(:pcloud_pvminstances_get).with("cloud-instance-id", "id-2").and_return(instance2)
      allow(provision).to receive(:create_and_attach_affinity_volumes)

      provision.check_task_clone(["id-1", "id-2"])

      expect(provision).not_to have_received(:create_and_attach_affinity_volumes)
    end

    it "attach_affinity_volumes calls create_and_attach_affinity_volumes for each instance and signals poll_destination_in_vmdb" do
      sm_provision = state_machine_class.new
      sm_provision.options = {:new_volumes => [{:name => "data", :size => 10}]}
      sm_provision.phase_context = {
        :active_instances => [
          {:id => "id-1", :server_name => "vm1"},
          {:id => "id-2", :server_name => "vm2"}
        ]
      }
      allow(sm_provision).to receive(:create_and_attach_affinity_volumes)
      allow(sm_provision).to receive(:signal)

      sm_provision.attach_affinity_volumes

      expect(sm_provision).to have_received(:create_and_attach_affinity_volumes).with("id-1", "vm1", 1).once
      expect(sm_provision).to have_received(:create_and_attach_affinity_volumes).with("id-2", "vm2", 2).once
      expect(sm_provision).to have_received(:signal).with(:poll_destination_in_vmdb)
      expect(sm_provision.phase_context[:active_instances]).to be_nil
    end

    it "uses a per-request sequence for replicated affinity volume names" do
      provision.options = {
        :new_volumes => [{:name => "data", :size => 10}],
        :replicants  => 4
      }
      provision.phase_context = {:new_volumes => []}

      volume_api = instance_double("PCloudVolumesApi")
      create_data_volume_class = Class.new do
        attr_reader :name, :affinity_pvm_instance

        def initialize(params)
          @name = params[:name]
          @affinity_pvm_instance = params[:affinity_pvm_instance]
        end
      end
      stub_const("IbmCloudPower::CreateDataVolume", create_data_volume_class)

      created_volume1 = double(:volume_id => "vol-1")
      created_volume2 = double(:volume_id => "vol-2")
      created_volume3 = double(:volume_id => "vol-3")
      created_volume4 = double(:volume_id => "vol-4")
      volume_requests = []

      allow(provision.source).to receive(:with_provider_connection).with(:service => "PCloudVolumesApi").and_yield(volume_api)
      allow(volume_api).to receive(:pcloud_cloudinstances_volumes_post) do |_cloud_instance_id, create_data_volume|
        volume_requests << create_data_volume
        [created_volume1, created_volume2, created_volume3, created_volume4][volume_requests.length - 1]
      end
      allow(volume_api).to receive(:pcloud_pvminstances_volumes_post)

      provision.create_and_attach_affinity_volumes("id-1", "vm1", 1)
      provision.create_and_attach_affinity_volumes("id-2", "vm2", 2)
      provision.create_and_attach_affinity_volumes("id-3", "vm3", 3)
      provision.create_and_attach_affinity_volumes("id-4", "vm4", 4)

      expect(volume_requests.map(&:name)).to eq(%w[data001 data002 data003 data004])
      expect(volume_requests.map(&:affinity_pvm_instance)).to eq(%w[vm1 vm2 vm3 vm4])
    end
  end

  context "clone_to_template" do
    let(:vm) { FactoryBot.create(:vm_ibm_cloud_power_virtual_servers, :ext_management_system => ems) }

    it 'supports publish' do
      expect(vm.supports?(:publish)).to be_truthy
    end

    it 'no publish if orphaned' do
      vm.update(:ems_id => nil)
      expect(vm.supports?(:publish)).to be_falsey
    end

    it 'no publish if archived' do
      vm.update(:ems_id => nil, :storage_id => nil)
      expect(vm.supports?(:publish)).to be_falsey
    end
  end
end
