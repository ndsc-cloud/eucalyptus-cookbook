#
# Cookbook Name:: eucalyptus
# Recipe:: configure
#
#Copyright [2014-2015] [Eucalyptus Systems]
##
##Licensed under the Apache License, Version 2.0 (the "License");
##you may not use this file except in compliance with the License.
##You may obtain a copy of the License at
##
##    http://www.apache.org/licenses/LICENSE-2.0
##
##    Unless required by applicable law or agreed to in writing, software
##    distributed under the License is distributed on an "AS IS" BASIS,
##    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
##    See the License for the specific language governing permissions and
##    limitations under the License.
##
require 'mixlib/shellout'

disable_proxy = 'http_proxy=""'
as_admin = "eval `clcadmin-assume-system-credentials` && "
command_prefix = "#{as_admin} #{node['eucalyptus']['home-directory']}"
describe_services = "#{command_prefix}/usr/bin/euserv-describe-services"
euctl = "#{command_prefix}/usr/bin/euctl"

if node['eucalyptus']['dns']['domain']
  execute "Enable DNS delegation" do
    command "#{euctl} bootstrap.webservices.use_dns_delegation=true"
    retries 15
    retry_delay 20
  end
  execute "Set DNS domain to #{node['eucalyptus']['dns']['domain']}" do
    command "#{euctl} system.dns.dnsdomain=#{node['eucalyptus']['dns']['domain']}"
    retries 15
    retry_delay 20
  end
  execute "Enable instance DNS" do
    command "#{euctl} bootstrap.webservices.use_instance_dns=true"
    retries 15
    retry_delay 20
  end
end

if node['riakcs_cluster']
  admin_key, admin_secret = RiakCSHelper::CreateUser.download_riak_credentials(node)
  Chef::Log.info "Existing RiakCS admin_key: #{admin_key}"
  Chef::Log.info "Existing RiakCS admin_secret: #{admin_secret}"
  execute "Set-objectstorage.providerclient-to-riakcs" do
    command "#{euctl} objectstorage.providerclient=riakcs"
    retries 15
    retry_delay 20
  end

  if node['riakcs_cluster']['topology']['load_balancer']
    if node['haproxy']['incoming_port']
      s3_endpoint = "#{node['riakcs_cluster']['topology']['load_balancer']}:#{node['haproxy']['incoming_port']}"
    else
      s3_endpoint = "#{node['riakcs_cluster']['topology']['load_balancer']}:80"
    end
  else
    s3_endpoint = "#{node['riakcs_cluster']['topology']['head']['ipaddr']}:8080"
  end

  execute "Set S3 endpoint" do
    command "#{euctl} objectstorage.s3provider.s3endpoint=#{s3_endpoint}"
    retries 15
    retry_delay 20
  end
  execute "Set providerclient access-key" do
    command "#{euctl} objectstorage.s3provider.s3accesskey=#{admin_key}"
    retries 5
    retry_delay 20
  end
  execute "Set providerclient secret-key" do
    command "#{euctl} objectstorage.s3provider.s3secretkey=#{admin_secret}"
    retries 5
    retry_delay 20
  end
elsif node['eucalyptus']['topology']['riakcs']
  execute "Set OSG providerclient to riakcs" do
    command "#{euctl} objectstorage.providerclient=riakcs"
    retries 15
    retry_delay 20
  end

  admin_key = node['eucalyptus']['topology']['riakcs']['access-key']
  admin_secret = node['eucalyptus']['topology']['riakcs']['secret-key']

  if admin_key == ""
    admin_key, admin_secret = RiakCSHelper::CreateUser.create_riakcs_user(
         node["eucalyptus"]["topology"]["riakcs"]["admin-name"],
         node["eucalyptus"]["topology"]["riakcs"]["admin-email"],
         node["eucalyptus"]["topology"]["riakcs"]["endpoint"],
         node["eucalyptus"]["topology"]["riakcs"]["port"],
    )

    node.set['eucalyptus']['topology']['riakcs']['access-key'] = admin_key
    node.set['eucalyptus']['topology']['riakcs']['secret-key'] = admin_secret
    node.save

    Chef::Log.info "RiakCS admin_key: #{admin_key}"
    Chef::Log.info "RiakCS admin_secret: #{admin_secret}"
  end

  execute "Set S3 endpoint" do
    command "#{euctl} objectstorage.s3provider.s3endpoint=#{node['eucalyptus']['topology']['riakcs']['endpoint']}"
    retries 15
    retry_delay 20
  end
  execute "#{euctl} objectstorage.s3provider.s3accesskey=#{admin_key}"
  execute "#{euctl} objectstorage.s3provider.s3secretkey=#{admin_secret}"
elsif node['eucalyptus']['topology']['ceph-radosgw']
  execute "Set OSG providerclient to ceph-rgw" do
    command "#{euctl} objectstorage.providerclient=ceph-rgw"
    retries 15
    retry_delay 20
  end
  execute "Set S3 endpoint for ceph-rgw" do
    command "#{euctl} objectstorage.s3provider.s3endpoint=#{node['eucalyptus']['topology']['ceph-radosgw']['endpoint']}"
    retries 15
    retry_delay 20
  end

  ceph_access_key = node['eucalyptus']['topology']['ceph-radosgw']['access-key']
  ceph_secret_key = node['eucalyptus']['topology']['ceph-radosgw']['secret-key']

  if ceph_access_key == nil || ceph_secret_key == nil
    found = CephHelper::SetCephRbd.get_radosgw_user_creds(node)
    ceph_access_key = found['eucalyptus']['topology']['ceph-radosgw']['access-key']
    ceph_secret_key = found['eucalyptus']['topology']['ceph-radosgw']['secret-key']
  end

  execute "#{euctl} objectstorage.s3provider.s3accesskey=#{ceph_access_key}"
  execute "#{euctl} objectstorage.s3provider.s3secretkey=#{ceph_secret_key}"
  execute "#{euctl} objectstorage.s3provider.s3endpointheadresponse=200"
else
  execute "Set OSG providerclient" do
    # for the short term due to errors in CI, run with --debug
    command "#{euctl} --debug objectstorage.providerclient=walrus"
    only_if "egrep '4.[0-9].[0-9]' #{node['eucalyptus']['home-directory']}/etc/eucalyptus/eucalyptus-version"
    retries 15
    retry_delay 20
    subscribes :start, "service[ufs-eucalyptus-cloud]", :immediately
    action :nothing
  end

  ruby_block "Block until objectstorage.providerclient ready" do
    block do
        # stole loop from:
        # https://github.com/chef-cookbooks/aws/blob/bd40e6c668e3975a1bbb1e82361c462db646c221/providers/elastic_ip.rb#L70-L89
        begin
            # Timeout.timeout() apparently can't take the #{} chef
            # variable construct so use ruby @ instance variable instead
            @seconds = node['eucalyptus']['configure-service-timeout']
            Timeout.timeout(@seconds) do
                Chef::Log.info "Setting a #{node['eucalyptus']['configure-service-timeout']} second timeout and waiting for objectstorage.providerclient to be ready for configuration..."
                loop do
                    if EucalyptusHelper.getservicestates?("objectstorage",["enabled", "broken"])
                        Chef::Log.info "objectstorage service ready, continuing..."
                        break
                    else
                        Chef::Log.info "objectstorage service state not ready, sleeping 5 seconds."
                    end
                    sleep 5
                end
            end
            rescue Timeout::Error
                raise "Timed out waiting for objectstorage.providerclient to be ready after #{node['eucalyptus']['configure-service-timeout']} seconds"
            end
    end
    notifies :run, 'execute[Set OSG providerclient]', :immediately
  end

end

if Eucalyptus::Enterprise.is_enterprise?(node)
  if Eucalyptus::Enterprise.is_san?(node)
    node['eucalyptus']['topology']['clusters'].each do |cluster, info|
      case info['storage-backend']
      when 'emc-vnx'
        san_package = 'eucalyptus-enterprise-storage-san-emc-libs'
      when 'netapp'
        san_package = 'eucalyptus-enterprise-storage-san-netapp-libs'
      when 'equallogic'
        san_package = 'eucalyptus-enterprise-storage-san-equallogic-libs'
      when 'threepar'
        san_package = 'eucalyptus-enterprise-storage-san-threepar-libs'
      else
        # This cluster is not SAN backed
        san_package = nil
      end
      if san_package and node["eucalyptus"]["install-type"] == "packages"
        yum_package san_package do
          action :upgrade
          options node['eucalyptus']['yum-options']
          notifies :restart, "service[eucalyptus-cloud]", :immediately
          flush_cache [:before]
        end
      end
    end
  end
end

%w{objectstorage compute cloudformation}.each do |service|
  execute "Wait for enabled #{service}" do
    command "#{describe_services} --filter service-type=#{service} | grep enabled"
    retries 15
    retry_delay 20
  end
end

execute "Set DNS server on CLC" do
  command "#{euctl} system.dns.nameserveraddress=#{node["eucalyptus"]["network"]["dns-server"]}"
end

file "#{node['eucalyptus']['admin-cred-dir']}/network.json" do
  content JSON.pretty_generate(node['eucalyptus']['network']['config-json'], quirks_mode: true)
  mode '644'
  action :create
end
execute "Configure network" do
  command "#{euctl} cloud.network.network_configuration=@#{node['eucalyptus']['admin-cred-dir']}/network.json"
end

clusters = node["eucalyptus"]["topology"]["clusters"]
clusters.each do |cluster, info|
  Chef::Log.info "Setting storage backend on cluster: #{cluster}"
  Chef::Log.info "Cluster info: #{info}"

  ### Set backend
  storage_backend = "overlay"
  if info["storage-backend"]
    storage_backend = info["storage-backend"]
  else

  end

  ruby_block "Block until #{cluster}.storage.blockstoragemanager ready" do
    block do
        # stole loop from:
        # https://github.com/chef-cookbooks/aws/blob/bd40e6c668e3975a1bbb1e82361c462db646c221/providers/elastic_ip.rb#L70-L89
        begin
            # Timeout.timeout() apparently can't take the #{} chef
            # variable construct so use ruby @ instance variable instead
            @seconds = node['eucalyptus']['configure-service-timeout']
            Timeout.timeout(@seconds) do
                Chef::Log.info "Setting a #{node['eucalyptus']['configure-service-timeout']} second timeout and waiting for #{cluster}.storage.blockstoragemanager to be ready for configuration..."
                loop do
                    if EucalyptusHelper.getservicestates?("storage", ["enabled", "broken"], cluster)
                        Chef::Log.info "Storage service ready, continuing..."
                        break
                    else
                        Chef::Log.info "Storage service state not ready, sleeping 5 seconds."
                    end
                    sleep 5
                end
            end
            rescue Timeout::Error
                raise "Timed out waiting for #{cluster}.storage.blockstoragemanager to be ready after #{node['eucalyptus']['configure-service-timeout']} seconds"
            end
    end
  end

  # if we reach this point we received a successful result from the ruby_block above
  execute "Set blockstoragemanager" do
    command lazy { "#{euctl} #{cluster}.storage.blockstoragemanager=#{storage_backend}" }
    not_if "#{euctl} #{cluster}.storage.blockstoragemanager | grep #{storage_backend}"
    retries 15
    retry_delay 20
  end

  ### Configure backend
  case info["storage-backend"]
  when "das"
    execute "Set das device" do
      Chef::Log.info "Setting #{cluster}.storage.dasdevice to #{info["das-device"]}"
      # for the short term due to errors in CI, run with --debug
      command "#{euctl} -n --debug #{cluster}.storage.dasdevice=#{info["das-device"]}"
      retries 15
      retry_delay 20
    end
  end
end

### Register Service Image
yum_repository "eucalyptus-service-image" do
  description "Eucalyptus Service Image Repo"
  url node["eucalyptus"]["service-image-repo"]
  gpgcheck false
  only_if { node['eucalyptus']['service-image-repo'] != "" }
end

yum_package "eucalyptus-service-image" do
  action :upgrade
  options node['eucalyptus']['yum-options']
  only_if { node['eucalyptus']['install-service-image'] }
end

execute "Set imaging VM instance type" do
  command "#{euctl} services.imaging.worker.instance_type=#{node['eucalyptus']['imaging-vm-type']}"
  retries 15
  retry_delay 20
  only_if { node['eucalyptus']['imaging-vm-type'] }
end

execute "Set loadbalancing VM instance type" do
  command "#{euctl} services.loadbalancing.worker.instance_type=#{node['eucalyptus']['loadbalancing-vm-type']}"
  retries 15
  retry_delay 20
  only_if { node['eucalyptus']['loadbalancing-vm-type'] }
end

# Determine what command to use to install service image
# In faststart (cloud-in-a-box) we create admin creds first and
# don't use the #{as_admin} prefix to the command
exp_run_list = node['expanded_run_list']
exp_run_list.each do |listitem|
  if listitem.include? "create-first-resources"
    Chef::Log.info "In faststart (cloud-in-a-box) installation, will create admin creds before installing service image."
    faststart_ini = "/root/.euca/faststart.ini"
    directory '/root/.euca'
    execute "Create admin credentials" do
      command "#{as_admin} euare-useraddkey admin -wld #{node["eucalyptus"]["dns"]["domain"]} -w > #{faststart_ini} --region localhost"
      creates faststart_ini
    end
    bash "Set default region" do
       user "root"
       code <<-EOF
          echo '[global]' >> #{faststart_ini}
          echo 'default-region = localhost' >> #{faststart_ini}
       EOF
       not_if "grep -q default-region #{faststart_ini}"
    end
    node.default['faststart_running']=true
  else
    node.default['faststart_running']=false
  end
end

ruby_block "Install Service Image" do
  block do

    osg_urls = []
    # Add the service url for each OSG to try next
    node["eucalyptus"]["topology"]["user-facing"].each do |ufs|
      osg_urls.push("http://#{ufs}:8773/services/objectstorage/")
    end

    if node['eucalyptus']['dns']['domain']
      osg_urls.push("http://s3.#{node["eucalyptus"]["dns"]["domain"]}:8773/")
    end
    osg_urls.each do |osg_url|
      Chef::Log.info "Attempting to install service image using s3 url: #{osg_url}"
      cmd = Mixlib::ShellOut::new("#{euctl} services.imaging.worker.image")
      cmd.run_command
      service_image = {
        :result => cmd.stdout,
        :is_configured => cmd.stdout !~ /NULL/,
        :error => cmd.stderr
      }
      Chef::Log.info "#{service_image}"
      if !service_image[:error].empty?
        raise Exception.new("Failed to fetch property because of: #{service_image[:error]}")
      end
      
      if service_image[:is_configured]
        break
      else
        if node.default['faststart_running']
          Chef::Log.info "running service image installation command: esi-install-image --region admin@localhost --install-default"
          cmd = Mixlib::ShellOut.new("esi-install-image --region admin@localhost --install-default")
        else
          Chef::Log.info "running service image installation command: #{as_admin} S3_URL=#{osg_url} esi-install-image --region localhost --install-default"
          cmd = Mixlib::ShellOut.new("#{as_admin} S3_URL=#{osg_url} esi-install-image --region localhost --install-default")
        end
        cmd.run_command
        Chef::Log.info "cmd.stdout: #{cmd.stdout}"
        if !cmd.stderr.empty?
          Chef::Log.info "cmd.stderr: #{cmd.stderr}"
          raise Exception.new("Failed to install Service Image")
        end
      end
    end
  end
  only_if { node['eucalyptus']['install-service-image'] }
end

execute "create_imaging_worker" do
  command "#{as_admin} esi-manage-stack --region localhost -a create imaging"
  only_if "#{euctl} services.imaging.worker.configured | grep 'false'"
  only_if { node['eucalyptus']['install-service-image'] }
end

node['eucalyptus']['system-properties'].each do |key, value|
  execute "#{euctl} #{key}=\"#{value}\"" do
    retries 10
    retry_delay 5
    not_if "#{euctl} #{key} | grep \"#{value}\""
  end
end

if node['eucalyptus']['network']['mode'] == 'VPCMIDO'
  execute 'Create default VPC for eucalyptus account' do
    command "#{as_admin} euca-create-vpc `euare-accountlist | grep '^eucalyptus' | awk '{print $2}'` --region localhost"
    not_if "#{as_admin} euca-describe-vpcs --region localhost | grep 'VPC.*default.*true'"
  end
end

## Post script
if node['eucalyptus']['post-script-url'] != ""
  remote_file "#{node['eucalyptus']['home-directory']}/post.sh" do
    source node['eucalyptus']['post-script-url']
    mode "777"
  end
  execute 'Running post script' do
    command "bash #{node['eucalyptus']['home-directory']}/post.sh"
  end
end
