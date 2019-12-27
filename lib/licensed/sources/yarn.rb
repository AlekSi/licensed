# frozen_string_literal: true
require "json"

module Licensed
  module Sources
    class Yarn < Source
      def enabled?
        return unless Licensed::Shell.tool_available?("yarn") && Licensed::Shell.tool_available?("npm")

        config.pwd.join("package.json").exist? && config.pwd.join("yarn.lock").exist?
      end

      def enumerate_dependencies
        packages.map do |name, package|
          Dependency.new(
            name: name,
            version: package["version"],
            path: package["path"],
            metadata: {
              "type"     => Yarn.type,
              "name"     => package["name"],
              "summary"  => package["description"],
              "homepage" => package["homepage"]
            }
          )
        end
      end

      def packages
        root_dependencies = JSON.parse(yarn_list_command)["data"]["trees"]
        root_path = config.pwd
        all_dependencies = {}
        recursive_dependencies(root_path, root_dependencies).each do |name, results|
          results.uniq! { |package| package["version"] }
          if results.size == 1
            all_dependencies[name] = results[0]
          else
            results.each do |package|
              all_dependencies[package["id"].sub("@", "-")] = package
            end
          end
        end

        Parallel.map(all_dependencies) { |name, dep| [name, package_info(dep)] }.to_h
      end

      # Recursively parse dependency JSON data.  Returns a hash mapping the
      # package name to it's metadata
      def recursive_dependencies(path, dependencies, result = {})
        dependencies.each do |dependency|
          next if dependency["shadow"]
          name, version = dependency["name"].split("@")

          dependency_path = path.join("node_modules", name)
          (result[name] ||= []) << {
            "id" => dependency["name"],
            "name" => name,
            "version" => version,
            "path" => dependency_path
          }
          recursive_dependencies(dependency_path, dependency["children"], result)
        end
        result
      end

      # Returns the output from running `yarn list` to get project dependencies
      def yarn_list_command
        args = %w(--json -s --no-progress)
        args << "--production" unless include_non_production?
        Licensed::Shell.execute("yarn", "list", *args, allow_failure: true)
      end

      # Returns extended information for the package
      def package_info(package)
        info = package_info_command(package["id"])
        return package if info.nil? || info.empty?

        info = JSON.parse(info)["data"]
        package.merge(
          "description" => info["description"],
          "homepage" => info["homepage"]
        )
      end

      # Returns the output from running `yarn info` to get package info
      def package_info_command(id)
        Licensed::Shell.execute("yarn", "info", "-s", "--json", id, allow_failure: true)
      end

      # Returns whether to include non production dependencies based on the licensed configuration settings
      def include_non_production?
        config.dig("yarn", "production_only") == false
      end
    end
  end
end