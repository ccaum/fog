require 'digest/sha2'

module Fog
  module Compute
    class Vsphere < Fog::Service

      requires :vsphere_username, :vsphere_password, :vsphere_server
      recognizes :vsphere_port, :vsphere_path, :vsphere_ns
      recognizes :vsphere_rev, :vsphere_ssl, :vsphere_expected_pubkey_hash

      model_path 'fog/vsphere/models/compute'
      model :server
      collection :servers

      request_path 'fog/vsphere/requests/compute'
      request :current_time
      request :find_vm_by_ref
      request :list_virtual_machines
      request :vm_power_off
      request :vm_power_on
      request :vm_reboot
      request :vm_clone
      request :vm_destroy

      module Shared

        attr_reader :vsphere_is_vcenter
        attr_reader :vsphere_rev
        attr_reader :vsphere_server
        attr_reader :vsphere_username

        ATTR_TO_PROP = {
          :id => 'config.instanceUuid',
          :name => 'name',
          :uuid => 'config.uuid',
          :instance_uuid => 'config.instanceUuid',
          :hostname => 'summary.guest.hostName',
          :operatingsystem => 'summary.guest.guestFullName',
          :ipaddress => 'guest.ipAddress',
          :power_state => 'runtime.powerState',
          :connection_state => 'runtime.connectionState',
          :host => 'runtime.host',
          :tools_state => 'guest.toolsStatus',
          :tools_version => 'guest.toolsVersionStatus',
          :is_a_template => 'config.template'
        }

        # Utility method to convert a VMware managed object into an attribute hash.
        # This should only really be necessary for the real class.
        # This method is expected to be called by the request methods
        # in order to massage VMware Managed Object References into Attribute Hashes.
        def convert_vm_mob_ref_to_attr_hash(vm_mob_ref)
          return nil unless vm_mob_ref

          props = vm_mob_ref.collect! *ATTR_TO_PROP.values.uniq
          Hash[ATTR_TO_PROP.map { |k,v| [k.to_s, props[v]] }].tap do |attrs|
            attrs['id'] ||= vm_mob_ref._ref
            attrs['mo_ref'] = vm_mob_ref._ref

            #I can't find how to not have this fail other than begin/rescue
            begin
              attrs['hypervisor'] = attrs['host'].name
            rescue
              attrs['hypervisor'] = nil
            end

            #I can't find how to not have this fail other than begin/rescue
            begin
              attrs['mac_addresses'] = vm_mob_ref.macs
            rescue
              attrs['mac_addresses'] = nil
            end

            attrs['path'] = get_folder_path(vm_mob_ref.parent)
          end
        end

      end

      class Mock

        include Shared

        def initialize(options={})
          @vsphere_username = options[:vsphere_username]
          @vsphere_password = 'REDACTED'
          @vsphere_server   = options[:vsphere_server]
          @vsphere_expected_pubkey_hash = options[:vsphere_expected_pubkey_hash]
          @vsphere_is_vcenter = true
          @vsphere_rev = '4.0'
        end

      end

      class Real

        include Shared

        def initialize(options={})
          require 'rbvmomi'
          @vsphere_username = options[:vsphere_username]
          @vsphere_password = options[:vsphere_password]
          @vsphere_server   = options[:vsphere_server]
          @vsphere_port     = options[:vsphere_port] || 443
          @vsphere_path     = options[:vsphere_path] || '/sdk'
          @vsphere_ns       = options[:vsphere_ns] || 'urn:vim25'
          @vsphere_rev      = options[:vsphere_rev] || '4.0'
          @vsphere_ssl      = options[:vsphere_ssl] || true
          @vsphere_expected_pubkey_hash = options[:vsphere_expected_pubkey_hash]
          @vsphere_must_reauthenticate = false

          @connection = nil
          # This is a state variable to allow digest validation of the SSL cert
          bad_cert = false
          loop do
            begin
              @connection = RbVmomi::VIM.new :host => @vsphere_server,
                                             :port => @vsphere_port,
                                             :path => @vsphere_path,
                                             :ns   => @vsphere_ns,
                                             :rev  => @vsphere_rev,
                                             :ssl  => @vsphere_ssl,
                                             :insecure => bad_cert
              break
            rescue OpenSSL::SSL::SSLError
              raise if bad_cert
              bad_cert = true
            end
          end

          if bad_cert then
            validate_ssl_connection
          end

          # Negotiate the API revision
          if not options[:vsphere_rev]
            rev = @connection.serviceContent.about.apiVersion
            @connection.rev = [ rev, ENV['FOG_VSPHERE_REV'] || '4.1' ].min
          end

          @vsphere_is_vcenter = @connection.serviceContent.about.apiType == "VirtualCenter"
          @vsphere_rev = @connection.rev

          authenticate
        end

        private

        def authenticate
          begin
            @connection.serviceContent.sessionManager.Login :userName => @vsphere_username,
                                                            :password => @vsphere_password
          rescue RbVmomi::VIM::InvalidLogin => e
            raise Fog::Vsphere::Errors::ServiceError, e.message
          end
        end

        # Verify a SSL certificate based on the hashed public key
        def validate_ssl_connection
          pubkey = @connection.http.peer_cert.public_key
          pubkey_hash = Digest::SHA2.hexdigest(pubkey.to_s)
          expected_pubkey_hash = @vsphere_expected_pubkey_hash
          if pubkey_hash != expected_pubkey_hash then
            raise Fog::Vsphere::Errors::SecurityError, "The remote system presented a public key with hash #{pubkey_hash} but we're expecting a hash of #{expected_pubkey_hash || '<unset>'}.  If you are sure the remote system is authentic set vsphere_expected_pubkey_hash: <the hash printed in this message> in ~/.fog"
          end
        end

      end

    end
  end
end
