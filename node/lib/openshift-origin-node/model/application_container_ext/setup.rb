module OpenShift
  module Runtime
    module ApplicationContainerExt
      module Setup
        # Private: Create and populate the users home dir.
        #
        # Examples
        #   initialize_homedir
        #   # => nil
        #   # Creates:
        #   # ~
        #   # ~/.tmp/
        #   # ~/.sandbox/$uuid
        #   # ~/.env/
        #   # APP_UUID, GEAR_UUID, APP_NAME, APP_DNS, HOMEDIR, DATA_DIR, \
        #   #   GEAR_DNS, GEAR_NAME, PATH, REPO_DIR, TMP_DIR, HISTFILE
        #   # ~/app-root
        #   # ~/app-root/data
        #   # ~/app-root/runtime/repo
        #   # ~/app-root/repo -> runtime/repo
        #   # ~/app-root/runtime/data -> ../data
        #
        # Returns nil on Success and raises on Failure.
        def initialize_homedir(basedir, homedir)
          notify_observers(:before_initialize_homedir)
          homedir = homedir.end_with?('/') ? homedir : homedir + '/'

          # Required for polyinstantiated tmp dirs to work
          [".tmp", ".sandbox"].each do |poly_dir|
            full_poly_dir = File.join(homedir, poly_dir)
            FileUtils.mkdir_p full_poly_dir
            FileUtils.chmod(0o0000, full_poly_dir)
          end

          # Polydir runs before the marker is created so set up sandbox by hand
          sandbox_uuid_dir = File.join(homedir, ".sandbox", @uuid)
          FileUtils.mkdir_p sandbox_uuid_dir
          PathUtils.oo_chown(@uuid, nil, sandbox_uuid_dir)

          env_dir = File.join(homedir, ".env")
          FileUtils.mkdir_p(env_dir)
          FileUtils.chmod(0o0750, env_dir)
          PathUtils.oo_chown(nil, @uuid, env_dir)

          ssh_dir = File.join(homedir, ".ssh")
          FileUtils.mkdir_p(ssh_dir)
          FileUtils.chmod(0o0750, ssh_dir)
          PathUtils.oo_chown(nil, @uuid, ssh_dir)

          gem_home = File.join(homedir, ".gem")
          add_env_var "GEM_HOME", gem_home
          add_env_var "OPENSHIFT_RUBYGEMS_PATH_ELEMENT", File.join(gem_home, "bin")
          FileUtils.mkdir_p(gem_home)
          FileUtils.chmod(0o0750, gem_home)
          set_rw_permission(gem_home)

          geardir = File.join(homedir, @container_name, "/")
          gearappdir = File.join(homedir, "app-root", "/")

          add_env_var("APP_DNS",
                      "#{@application_name}-#{@namespace}.#{@config.get("CLOUD_DOMAIN")}",
                      true)
          add_env_var("APP_NAME", @application_name, true)
          add_env_var("APP_UUID", @application_uuid, true)

          data_dir = File.join(gearappdir, "data", "/")
          add_env_var("DATA_DIR", data_dir, true) {|v|
            FileUtils.mkdir_p(v, :verbose => @debug)
          }
          add_env_var("HISTFILE", File.join(data_dir, ".bash_history"))
          profile = File.join(data_dir, ".bash_profile")
          File.open(profile, File::WRONLY|File::TRUNC|File::CREAT, 0o0600) {|file|
          file.write %Q{
# Warning: Be careful with modifications to this file,
#          Your changes may cause your application to fail.
}
          }
          PathUtils.oo_chown(@uuid, @uuid, profile, :verbose => @debug)


          add_env_var("GEAR_DNS",
                      "#{@container_name}-#{@namespace}.#{@config.get("CLOUD_DOMAIN")}",
                      true)
          add_env_var("GEAR_NAME", @container_name, true)
          add_env_var("GEAR_UUID", @uuid, true)

          add_env_var("HOMEDIR", homedir, true)

          # Ensure HOME exists for git support
          add_env_var("HOME", homedir, false)

          add_env_var("REPO_DIR", File.join(gearappdir, "runtime", "repo", "/"), true) {|v|
            FileUtils.mkdir_p(v, :verbose => @debug)
            FileUtils.cd gearappdir do |d|
              FileUtils.ln_s("runtime/repo", "repo", :verbose => @debug)
            end
            FileUtils.cd File.join(gearappdir, "runtime") do |d|
              FileUtils.ln_s("../data", "data", :verbose => @debug)
            end
          }

          add_env_var("TMP_DIR", "/tmp/", true)
          add_env_var("TMP_DIR", "/tmp/", false)
          add_env_var("TMPDIR", "/tmp/", false)
          add_env_var("TMP", "/tmp/", false)

          # Update all directory entries ~/app-root/*
          Dir[gearappdir + "/*"].entries.reject{|e| [".", ".."].include? e}.each {|e|
            FileUtils.chmod_R(0o0750, e, :verbose => @debug)
            PathUtils.oo_chown_R(@uuid, @uuid, e, :verbose => @debug)
          }
          PathUtils.oo_chown(nil, @uuid, gearappdir, :verbose => @debug)
          raise "Failed to instantiate gear: missing application directory (#{gearappdir})" unless File.exist?(gearappdir)

          state_file = File.join(gearappdir, "runtime", ".state")
          File.open(state_file, File::WRONLY|File::TRUNC|File::CREAT, 0o0660) {|file|
            file.write "new\n"
          }
          PathUtils.oo_chown(@uuid, @uuid, state_file, :verbose => @debug)

          OpenShift::Runtime::FrontendHttpServer.new(@uuid,@container_name,@namespace).create

          # Fix SELinux context for cart dirs
          Utils::SELinux.clear_mcs_label_R(homedir)
          Utils::SELinux.set_mcs_label_R(Utils::SELinux.get_mcs_label(@uid), Dir.glob(File.join(homedir, '*')))
        end

        # Private: Determine next available user id.  This is usually determined
        #           and provided by the broker but is auto determined if not
        #           provided.
        #
        # Examples:
        #   next_uid =>
        #   # => 504
        #
        # Returns Integer value for next available uid.
        def next_uid
          uids = IO.readlines("/etc/passwd").map{ |line| line.split(":")[2].to_i }
          gids = IO.readlines("/etc/group").map{ |line| line.split(":")[2].to_i }
          min_uid = (@config.get("GEAR_MIN_UID") || "500").to_i
          max_uid = (@config.get("GEAR_MAX_UID") || "1500").to_i

          (min_uid..max_uid).each do |i|
            if !uids.include?(i) and !gids.include?(i)
              return i
            end
          end
        end
      end
    end
  end
end