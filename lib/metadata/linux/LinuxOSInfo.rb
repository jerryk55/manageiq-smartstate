require 'util/miq-xml'

module MiqLinux
  class OSInfo
    attr_reader :os, :networks

    ETC = "/etc"
    IFCFGFILE = "/etc/sysconfig/network-scripts"
    DHCLIENTFILE = "/var/lib/dhclient/"
    DEBIANDHCLIENTFILE = "/var/lib/dhcp3/"
    DEBIANIFCFGILE = "/etc/network"
    DISTRIBUTIONS = ["mandriva", "mandrake", "mandrakelinux", "gentoo", "SuSE", "fedora", "redhat", "knoppix", "debian", "lsb", "distro"]

    def initialize(fs)
      @fs = fs
      @os_type = "Linux"
      @distribution = ""
      @description  = ""
      @hostname     = ""

      @networks = []
      @os = {}

      process_distributions
      process_networking(fs)

      @os = {:type => "linux", :machine_name => @hostname, :product_type => @os_type, :distribution => @distribution, :product_name => @description}
      $log.info("VM OS information: [#{@os.inspect}]") if $log
    end

    def process_distributions
      release_file = nil
      saved_distribution = nil
      DISTRIBUTIONS.each do |dist|
        release_file = File.join(ETC, dist + "-release")

        if fs.fileExists?(release_file)
          saved_distribution = @distribution = dist
        end
      end

      if @distribution == "lsb"
        process_lsb_distribution(fs, release_file)
      elsif !@distribution.empty?
        process_redhat_distribution(fs, release_file)
      elsif (@distribution = saved_distribution).empty?
        process_hercules_distribution(fs)
      else
        fs.fileOpen(release_file) { |fo| @description = fo.read.chomp }
      end

      @description  = @description.gsub(/^"/, "").gsub(/"$/, "")
    end

    def process_redhat_distribution(fs, release_file)
      fs.fileOpen(release_file) { |fo| @description = fo.read.to_s.chomp }
      @distribution = "CentOS" if @distribution == "redhat" && @description.include?("CentOS")
      @distribution = "rPath"  if @distribution == "distro"
    end

    def process_lsb_distribution(fs, release_file)
      lsbd = ""
      fs.fileOpen(release_file) { |fo| lsbd = fo.read }

      dist = desc = chrome_dist = chrome_desc = nil
      lsbd.each_line do |lsbl|
        case lsbl
        when /^\s*DISTRIB_ID\s*=\s*(.*)$/
          @distribution = dist = $1
        when /^\s*DISTRIB_DESCRIPTION\s*=\s*(.*)$/
          @description = desc = $1
        when /^\s*CHROMEOS_RELEASE_NAME\s*=\s*(.*)$/
          @distribution = chrome_dist = $1
        when /^\s*CHROMEOS_RELEASE_DESCRIPTION\s*=\s*(.*)$/
          @description = chrome_desc = $1
        end
      end
      @description = "#{chrome_dist} #{chrome_desc}" if chrome_dist && chrome_desc
    end

    def process_hercules_distribution(fs)
      read_file(fs, File.join(ETC, "issue")) do |line|
        case line
        when /\s*Hercules\s*/
          @distribution = "hercules"
          @description =  "Hercules"
          break
        end
      end
    end

    def process_networking(fs)
      hostname_from_files(fs)
      network_attrs = {:hostname => @hostname}
      # Collect network settings
      case @distribution.downcase
      when "ubuntu" then networking_debian(fs, network_attrs)
      when "redhat", "fedora" then networking_redhat(fs, network_attrs)
      when "hercules" then networking_hercules(fs, network_attrs)
      end
    end

    def hostname_from_files(fs)
      hostname_from_hostname_files(fs)
      hostname_from_network_files(fs)
    end

    def hostname_from_hostname_files(fs)
      ["/etc/hostname", "/etc/HOSTNAME"].each do |hnf|
        next unless fs.fileExists?(hnf)
        fs.fileOpen(hnf) { |fo| @hostname = fo.read.chomp }
      end
    end

    def hostname_from_network_files(fs)
      ["/etc/conf.d/hostname", "/etc/sysconfig/network"].each do |hnf|
        next unless fs.fileExists?(hnf)
        next if fs.fileDirectory?(hnf)
        process_network_file(fs, hnf)
      end
    end

    def process_network_file(fs, hostname_file)
      read_file(fs, hostname_file) do |hnfl|
        case hnfl
        when /^\s*HOSTNAME\s*=\s*(.*)$/
          @hostname = $1
          break
        end
      end
    end

    def networking_debian(fs, attrs)
      read_file(fs, File.join(DEBIANIFCFGILE, "interfaces")) do |line|
        case line
        when /^\s*iface eth0 inet dhcp\s*(.*)$/ then attrs[:dhcp_enabled] = 1
        when /^\s*iface eth0 inet static\s*(.*)$/ then attrs[:dhcp_enabled] = 0
        when /^\s*address\s*(.*)$/ then attrs[:ipaddress] = $1
        when /^\s*netmask\s*(.*)$/ then attrs[:subnet_mask] = $1
        when /^\s*gateway\s*(.*)$/ then attrs[:default_gateway] = $1
        when /^\s*network\s*(.*)$/ then attrs[:network] = $1
        end
      end

      attrs.merge!(parse_dh_client_file(DEBIANDHCLIENTFILE)) if attrs[:dhcp_enabled] == 1
      fix_attr_values(attrs)
      @networks << attrs
    end

    def networking_redhat(fs, attrs)
      read_file(fs, File.join(IFCFGFILE, "ifcfg-eth0")) do |line|
        case line
        when  /^\s*BOOTPROTO=dhcp\s*(.*)$/    then attrs[:dhcp_enabled] = 1
        when  /^\s*BOOTPROTO=static\s*(.*)$/  then attrs[:dhcp_enabled] = 0
        when  /^\s*DEVICE\s*=\s*(.*)$/        then attrs[:device] = $1
        when  /^\s*HWADDR\s*=\s*(.*)$/        then attrs[:hwaddr] = $1
          # static setting will have these entries
        when  /^\s*IPADDR\s*=\s*(.*)$/        then attrs[:ipaddress] = $1
        when  /^\s*NETMASK\s*=\s*(.*)$/       then attrs[:subnet_mask] = $1
          # static setting might have these entries
        when  /^\s*BROADCAST\s*=\s*(.*)$/     then attrs[:broadcast] = $1
        when  /^\s*NETWORK\s*=\s*(.*)$/       then attrs[:network] = $1
        end
      end

      attrs.merge!(parse_dh_client_file(DHCLIENTFILE)) if attrs[:dhcp_enabled] == 1
      fix_attr_values(attrs)
      @networks << attrs
    end

    def networking_hercules(fs, attrs)
      read_file(fs, File.join(DEBIANIFCFGILE, "interfaces")) do |line|
        case line
        when /^\s*iface eth0 inet dhcp\s*(.*)$/ then attrs[:dhcp_enabled] = 1
        when /^\s*iface eth0 inet static\s*(.*)$/ then attrs[:dhcp_enabled] = 0
        end
      end

      fix_attr_values(attrs)
      @networks << attrs
    end

    def toXml(doc = nil)
      doc = MiqXml.createDoc(nil) unless doc
      doc.add_element(:os, @os)
      networksToXml(doc)
      doc
    end

    def networksToXml(doc = nil)
      doc = MiqXml.createDoc(nil) unless doc
      unless @networks.empty?
        node = doc.add_element(:networks)
        @networks.each do |n|
          [:hwaddr, :network, :device, :broadcast].each { |key| n.delete(key) }
          node.add_element(:network, n)
        end
      end
      doc
    end

    def read_file(fs, filename)
      if fs.fileExists?(filename)
        file_content = ""
        fs.fileOpen(filename) { |fo| file_content = fo.read }
        unless file_content.nil?
          file_content.each_line { |line| yield(line.chomp) }
        end
      end
    end

    def fix_attr_values(attrs)
      # Clean the lease times and check they are in a reasonable range
      [:lease_obtained, :lease_expires].each do |t|
        if attrs[t] && attrs[t].to_i >= 0 && attrs[t].to_i < 0x80000000
          attrs[t] = Time.parse(attrs[t]).utc.iso8601
        else
          attrs.delete(t)
        end
      end

      attrs[:dns_server].gsub!(/(,)/) { (' ') } unless attrs[:dns_server].nil?
    end

    private

    def parse_dh_client_file(client_file)
      attribs = {}
      read_file(fs, File.join(client_file, "dhclient-eth0.leases")) do |line|
        case line
        when /^\s*fixed-address\s*(.*)\;$/                 then attribs[:ipaddress] = $1
        when /^\s*option subnet-mask\s*(.*)\;$/            then attribs[:subnet_mask] = $1
        when /^\s*option routers\s*(.*)\;$/                then attribs[:default_gateway] = $1
        when /^\s*option domain-name-servers\s*(.*)\;$/    then attribs[:dns_server] = $1
        when /^\s*option dhcp-server-identifier\s*(.*)\;$/ then attribs[:dhcp_server] = $1
        when /^\s*option domain-name\s*"*(.*)"\;$/         then attribs[:domain] = $1
        when /^\s*expire\s*[0-9]?\s*(.*)\;$/               then attribs[:lease_expires] = $1
        when /^\s*renew\s*[0-9]?\s*(.*)\;$/                then attribs[:lease_obtained] = $1
        end
      end
      attribs
    end
  end # class OSInfo
end # module MiqLinux
