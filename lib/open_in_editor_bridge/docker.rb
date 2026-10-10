# frozen_string_literal: true

require "open3"
require "tempfile"

class OpenInEditorBridge
  class Docker
    CONTAINER_DIRECTORY = "/open-in-editor-bridge"

    def initialize(env:, project_root:, service:, compose_options:)
      @env = env.to_h
      @project_root = File.expand_path(project_root || @env.fetch("OPEN_IN_EDITOR_PROJECT_ROOT", Dir.pwd))
      @service = service
      @compose_options = compose_options
    end

    def call(*args)
      return up(args) if args.first == "up"

      result = run(args)
      bridge.call("--shutdown") if args.first == "down"
      result
    end

    private

    def configuration
      @configuration ||= Configuration.new(env: @env, project_root: @project_root)
    end

    def bridge
      @bridge ||= OpenInEditorBridge.new(env: @env, project_root: @project_root)
    end

    def up(args)
      if %w[127.0.0.1 ::1 localhost].include?(configuration.bind_address)
        raise ArgumentError, "Docker editor access requires explicit OPEN_IN_EDITOR_BRIDGE_BIND_ADDRESS (for example 0.0.0.0 on a trusted network)."
      end
      raise ArgumentError, "Select a Compose service for the Vite integration" if @service.to_s.empty?

      # Resolve source files once with Compose, before acquiring a lease. Reuse
      # its canonical model rather than trying to reproduce file discovery.
      with_resolved_configuration do |resolved_file, profiles|
        with_override do |override|
          options = compose_options_for_resolved_configuration(profiles) +
            ["-f", resolved_file, "-f", override]
          detached?(args) ? detached_up(args, options) : foreground_up(args, options)
        end
      end
    end

    def foreground_up(args, options)
      lease = SecureRandom.hex(16)
      bridge.start_session(lease)
      begin
        run(args, options)
      ensure
        release_preserving_error(lease)
      end
    end

    def detached_up(args, options)
      registration = bridge.start_session("detached")
      run(args, options)
    rescue StandardError
      release_preserving_error("detached") if registration == :started
      raise
    end

    def release_preserving_error(lease)
      original_error = $!
      bridge.stop_session(lease)
    rescue StandardError
      raise unless original_error
    end

    def detached?(args)
      wait_flag = args.reverse_each.find { |arg| %w[--wait --wait=true --wait=false].include?(arg) }
      return true if wait_flag && wait_flag != "--wait=false"

      flags = args.select { |arg| %w[-d --detach --detach=true --detach=false -d=true -d=false].include?(arg) }
      !flags.empty? && !%w[--detach=false -d=false].include?(flags.last)
    end

    def run(args, compose_options = @compose_options)
      system(@env, "docker", "compose", *compose_options, *args,
        chdir: @project_root, exception: true)
    end

    def with_resolved_configuration
      Tempfile.create(["compose-resolved-", ".json"]) do |file|
        system(@env, "docker", "compose", *@compose_options, "config", "--format", "json",
          chdir: @project_root, out: file, exception: true)
        file.flush
        yield file.path, active_profiles
      end
    end

    def active_profiles
      output, error, status = Open3.capture3(@env, "docker", "compose", *@compose_options,
        "config", "--environment", chdir: @project_root)
      unless status.success?
        raise "Docker Compose config --environment failed (exit #{status.exitstatus}): #{error.strip}"
      end

      profiles = output.lines.find { |line| line.start_with?("COMPOSE_PROFILES=") }
      return [] unless profiles

      profiles.delete_prefix("COMPOSE_PROFILES=").strip.split(",").reject(&:empty?)
    end

    def compose_options_for_resolved_configuration(profiles)
      options = []
      skip_next = false
      @compose_options.each do |option|
        if skip_next
          skip_next = false
          next
        end
        if %w[-f --file --env-file].include?(option)
          skip_next = true
        elsif option.start_with?("--file=", "--env-file=") || option.match?(/\A-f.+/)
          next
        else
          options << option
        end
      end
      unless options.any? { |option| option == "--project-directory" || option.start_with?("--project-directory=") }
        options.concat(["--project-directory", @project_root])
      end
      profiles.each { |profile| options.concat(["--profile", profile]) }
      options
    end

    def with_override
      configuration.ensure_runtime_directory
      manifest = write_manifest
      mounts = [
        file_mount(File.join(__dir__, "vite.mjs"), "vite.mjs"),
        file_mount(manifest, "session.json"),
      ]
      override = { "services" => { @service => {
        "extra_hosts" => { "host.docker.internal" => "host-gateway" },
        "volumes" => mounts,
      } } }
      Tempfile.create(["compose-", ".json"], configuration.runtime_directory) do |file|
        file.write(JSON.generate(override))
        file.flush
        yield file.path
      end
    end

    def file_mount(source, name)
      { "type" => "bind", "source" => File.expand_path(source),
        "target" => "#{CONTAINER_DIRECTORY}/#{name}", "read_only" => true,
        "bind" => { "create_host_path" => false } }
    end

    def write_manifest
      path = File.join(configuration.runtime_directory, "docker-#{configuration.port}-#{configuration.session_id}.json")
      payload = { "session" => configuration.session_id, "target" => "http://host.docker.internal:#{configuration.port}" }
      # Atomic replacement keeps simultaneous starts from exposing a partial identity file.
      Tempfile.create(["session-", ".json"], configuration.runtime_directory) do |file|
        file.write(JSON.generate(payload))
        file.flush
        file.chmod(0o644)
        File.rename(file.path, path)
      end
      path
    end
  end
end
