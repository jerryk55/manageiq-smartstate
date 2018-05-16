require 'MiqVm/MiqVm'

class MiqRhevmVm < MiqVm
  RHEV_NFS_UID = 36

  def openDisks(diskFiles)
    mount_storage
    if @ost.nfs_storage_mounted
      $log.debug "MiqRhevmVm#openDisks: setting euid = #{RHEV_NFS_UID}"
      orig_uid = Process::UID.eid
      Process::UID.grant_privilege(RHEV_NFS_UID)
    end
    rv = super
    if @ost.nfs_storage_mounted
      $log.debug "MiqRhevmVm#openDisks: resetting euid = #{orig_uid}"
      Process::UID.grant_privilege(orig_uid)
    end
    rv
  end

  def get_vmconfig(vm_config)
    @rhevm = @ost.miqRhevm
    $log.debug("MiqVm::initialize: accessing VM through RHEVM server") if $log.debug?
    $log.debug("MiqVm::initialize: vmCfg = #{vmCfg}")
    @rhevmVm = @rhevm.get_vm(vm_config)
    $log.debug("MiqVm::initialize: setting @ost.miqRhevmVm = #{@rhevmVm.class}") if $log.debug?
    @ost.miqRhevmVm = @rhevmVm
    #
    # If we're passed a snapshot ID, then obtain the configuration of the
    # VM when the snapshot was taken.
    #
    @vmConfig = VmConfig.new(getCfg(@ost.snapId))
    $log.debug("MiqVm::initialize: @vmConfig.getHash = #{@vmConfig.getHash.inspect}")
    $log.debug("MiqVm::initialize: @vmConfig.getDiskFileHash = #{@vmConfig.getDiskFileHash.inspect}")
  end

  def unmount
    super
  ensure
    unmount_storage
  end

  def init_disk(d_info)
    d = applianceVolumeManager.lvHash[d_info.fileName] if applianceVolumeManager
    $log.debug("MiqVm::openDisks: using applianceVolumeManager for #{dInfo.fileName}") if $log.debug?
    d.dInfo.fileName               = d_info.fileName
    d.dInfo.hardwareId             = d_info.hardwareId
    d.dInfo.baseOnly               = d_info.baseOnly
    d.dInfo.format                 = d_info.format if d_info.format
    d.dInfo.applianceVolumeManager = applianceVolumeManager
    #
    # Here, we need to probe the disk to determine its data format,
    # QCOW for example. If the disk format is not flat, push a disk
    # supporting the format on top of this disk. Then set d to point
    # to the new top disk.
    #
    d.pushFormatSupport
  end

  def getCfg(_snap = nil)
    cfg_props = @rhevmVm.attributes

    raise MiqException::MiqVimError, "Failed to retrieve configuration information for VM" if cfg_props.nil?

    storage_domains = @rhevm.storagedomains
    $log.debug "MiqRhevmVm#getCfg: storage_domains = #{storage_domains.inspect}"

    cfg_hash = {}
    cfg_hash['displayname'] = cfg_props[:name]
    cfg_hash['guestos']     = cfg_props.fetch_path(:os, :type)
    cfg_hash['memsize']     = cfg_props[:memory] / 1_048_576  # in MB
    cfg_hash['numvcpu']     = cfg_props.fetch_path(:cpu, :sockets)

    # Collect disk information
    @rhevmVm.attributes[:disks] = @rhevmVm.send(:disks, :disk) if @rhevmVm[:disks].nil?
    @rhevmVm.disks.each_with_index do |disk, idx|
      $log.debug "MiqRhevmVm#getCfg: disk = #{disk.inspect}"
      storage_domain = disk[:storage_domains].first
      if storage_domain.nil?
        $log.info "Disk <#{disk[:name]}> is skipped due to unassigned storage domain"
        next
      end
      storage_id     = storage_domain && storage_domain[:id]
      storage_obj    = storage_domains_by_id[storage_id]

      file_path = file_path_for_storage_type(storage_obj, disk)

      tag = "scsi0:#{idx}"
      cfg_hash["#{tag}.present"]    = "true"
      cfg_hash["#{tag}.devicetype"] = "disk"
      cfg_hash["#{tag}.filename"]   = file_path.to_s
      cfg_hash["#{tag}.format"]     = disk[:format]
    end
    cfg_hash
  end

  def file_path_for_storage_type(storage_obj, disk)
    storage_type = storage_obj && storage_obj.attributes[:storage][:type]

    # TODO: account for other storage types here.
    case storage_type
    when "nfs", "glusterfs"
      add_fs_mount(storage_obj)
      fs_file_path(storage_obj, disk)
    else
      lun_file_path(storage_obj, disk)
    end
  end

  def nfs_mount_root
    @nfs_mount_root ||= @ost.nfs_mount_root || "/mnt/#{@rhevmVm.attributes[:id]}"
  end

  def fs_file_path(storage_obj, disk)
    storage_id  = storage_obj.attributes[:id]
    disk_id     = disk.attributes[:id]
    image_id    = disk.attributes[:image_id]
    mount_point = nfs_mounts[storage_id][:mount_point]

    ::File.join(mount_point, storage_id, 'images', disk_id, image_id)
  end

  def lun_file_path(storage_obj, disk)
    storage_id = storage_obj.attributes[:id]
    disk_id    = disk[:image_id].blank? ? disk.attributes[:id] : disk.attributes[:image_id]

    ::File.join('/dev', storage_id, disk_id)
  end

  def storage_domains_by_id
    @storage_domains_by_id ||= @rhevm.storagedomains.each_with_object({}) { |sd, sdh| sdh[sd.attributes[:id]] = sd }
  end

  #
  # Returns uri and mount points, hashed by storage ID.
  #
  def add_fs_mount(storage_obj)
    storage_id = storage_obj.attributes[:id]
    return if nfs_mounts[storage_id]

    mount_point = ::File.join(nfs_mount_root, nfs_mount_dir(storage_obj))
    type = storage_obj.attributes[:storage][:type]
    nfs_mounts[storage_id] = {
      :uri         => "#{type}://#{nfs_uri(storage_obj)}",
      :mount_point => mount_point,
      :read_only   => true,
      :type        => type
    }
  end

  def nfs_uri(storage_obj)
    storage = storage_obj.attributes[:storage]
    "#{storage[:address]}:#{storage[:path]}"
  end

  def nfs_mounts
    @nfs_mounts ||= {}
  end

  def nfs_mount_dir(storage_obj)
    nfs_uri(storage_obj).gsub("_", "__").tr("/", "_")
  end

  def mount_storage
    require 'util/mount/miq_nfs_session'
    require 'util/mount/miq_glusterfs_session'
    log_header = "MIQ(MiqRhevmVm.mount_storage)"
    $log.info "#{log_header} called"

    @ost.nfs_storage_mounted = false

    if nfs_mounts.empty?
      $log.info "#{log_header} storage mount not needed."
      return
    end

    begin
      FileUtils.mkdir_p(nfs_mount_root) unless File.directory?(nfs_mount_root)
      nfs_mounts.each do |storage_id, mount_info|
        $log.info "#{log_header} Mounting #{mount_info[:uri]} on #{mount_info[:mount_point]} for #{storage_id}"

        case mount_info[:type]
        when "nfs"
          MiqNfsSession.new(mount_info).connect
        when "glusterfs"
          MiqGlusterfsSession.new(mount_info).connect
        end

        @ost.nfs_storage_mounted = true
      end
      $log.info "#{log_header} - mount:\n#{`mount`}"
    rescue
      $log.error "#{log_header} Unable to mount all items from <#{nfs_mount_root}>"
      unmount_storage
      raise $!
    end
  end

  # Moved from MIQExtract.rb
  def unmount_storage
    log_header = "MIQ(MiqRhevmVm.unmount_storage)"
    return if nfs_mounts.empty?
    begin
      $log.warn "#{log_header} Unmount all items from <#{nfs_mount_root}>"
      nfs_mounts.each_value { |mnt| MiqNfsSession.disconnect(mnt[:mount_point]) }
      FileUtils.rm_rf(nfs_mount_root)
      @ost.nfs_storage_mounted = false
    rescue
      $log.warn "#{log_header} Failed to unmount all items from <#{nfs_mount_root}>.  Reason: <#{$!}>"
    end
  end
end
