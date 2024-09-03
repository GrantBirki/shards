require "./command"
require "../molinillo_solver"

module Shards
  module Commands
    class Install < Command
      def run
        if Shards.frozen? && !lockfile?
          raise Error.new("Missing shard.lock")
        end
        check_symlink_privilege

        # debug info about the environment
        Log.debug { "Shards.crystal_version: #{Shards.crystal_version}" }
        Log.debug { "Shards.frozen?: #{Shards.frozen?}" }
        Log.debug { "Shards.local?: #{Shards.local?}" }
        Log.debug { "Shards.with_development?: #{Shards.with_development?}" }
        Log.debug { "Shards.skip_postinstall?: #{Shards.skip_postinstall?}" }
        Log.debug { "Shards.skip_executables?: #{Shards.skip_executables?}" }
        Log.debug { "Shards.cache_path: #{Shards.cache_path}" }

        Log.info { "Resolving dependencies" }

        solver = MolinilloSolver.new(spec, override)

        Log.debug { "Constructed solver" }

        if lockfile?
          # install must be as conservative as possible:
          solver.locks = locks.shards
          Log.debug { "Loaded locks" }
        end

        Log.debug { "Preparing solver" }
        solver.prepare(development: Shards.with_development?)
        Log.debug { "Prepared solver" }

        Log.debug { "Fetching packages" }
        packages = handle_resolver_errors { solver.solve }

        if Shards.frozen?
          Log.debug { "--frozen used - validating packages" }
          validate(packages)
          Log.debug { "Packages validated" }
        end

        Log.debug { "Installing packages" }
        install(packages)

        if generate_lockfile?(packages)
          write_lockfile(packages)
        elsif !Shards.frozen?
          # Touch lockfile so its mtime is bigger than that of shard.yml
          File.touch(lockfile_path)
        end

        # Touch install path so its mtime is bigger than that of the lockfile
        touch_install_path

        check_crystal_version(packages)
      end

      private def validate(packages)
        packages.each do |package|
          Log.debug { "validating #{package.name}" }
          if lock = locks.shards.find { |d| d.name == package.name }
            if lock.resolver != package.resolver
              raise LockConflict.new("#{package.name} source changed")
            else
              validate_locked_version(package, lock.version)
            end
          else
            raise LockConflict.new("can't install new dependency #{package.name} in production")
          end
        end
      end

      private def validate_locked_version(package, version)
        return if package.version == version
        raise LockConflict.new("#{package.name} requirements changed")
      end

      private def install(packages : Array(Package))
        Log.debug { "installing #{packages.size} packages" }

        # packages are returned by the solver in reverse topological order,
        # so transitive dependencies are installed first
        packages.each do |package|
          # first install the dependency:
          next unless install(package)

          # then execute the postinstall script
          # (with access to all transitive dependencies):
          package.postinstall

          # always install executables because the path resolver never actually
          # installs dependencies:
          package.install_executables
        end
      end

      private def install(package : Package)
        if package.installed?
          Log.info { "Using #{package.name} (#{package.report_version})" }
          return
        end

        if Shards.local?
          Log.info { "Using cached #{package.name} (#{package.report_version})" }
        else
          Log.info { "Installing #{package.name} (#{package.report_version})" }
        end

        package.install
        package
      end

      private def generate_lockfile?(packages)
        !Shards.frozen? && (!lockfile? || outdated_lockfile?(packages))
      end

      private def outdated_lockfile?(packages)
        return true if locks.version != Shards::Lock::CURRENT_VERSION
        return true if packages.size != locks.shards.size

        packages.index_by(&.name) != locks.shards.index_by(&.name)
      end
    end
  end
end
