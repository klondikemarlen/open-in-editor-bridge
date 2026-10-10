# frozen_string_literal: true

require "tempfile"

class OpenInEditorBridge
  class Docker
    CONTAINER_DIRECTORY = "/open-in-editor-bridge"
    COMPOSE_FILES = %w[compose.yaml compose.yml docker-compose.yaml docker-compose.yml].freeze
    OVERRIDE_FILES = %w[compose.override.yaml compose.override.yml docker-compose.override.yaml docker-compose.override.yml].freeze

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

      # Resolve Compose inputs before acquiring a lease; invalid setup must not leave a broker behind.
      files = compose_file_options
      with_override do |override|
        options = [*files, "-f", override]
        detached?(args) ? detached_up(args, options) : foreground_up(args, options)
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
      flags = args.select { |arg| %w[-d --detach --detach=true --detach=false -d=true -d=false].include?(arg) }
      !flags.empty? && !%w[--detach=false -d=false].include?(flags.last)
    end

    def run(args, extra_options = [])
      system(@env, "docker", "compose", *@compose_options, *extra_options, *args,
        chdir: @project_root, exception: true)
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

    def compose_file_options
      return [] if @compose_options.any? { |arg| arg == "-f" || arg == "--file" || arg.start_with?("--file=") || arg.match?(/\A-f.+/) }

      if @env["COMPOSE_FILE"] && !@env["COMPOSE_FILE"].empty?
        separator = @env.fetch("COMPOSE_PATH_SEPARATOR", File::PATH_SEPARATOR)
        return @env.fetch("COMPOSE_FILE").split(separator).flat_map { |path| ["-f", File.expand_path(path, @project_root)] }
      end

      directory = discovery_directory
      loop do
        base = COMPOSE_FILES.find { |name| File.file?(File.join(directory, name)) }
        if base
          override = OVERRIDE_FILES.find { |name| File.file?(File.join(directory, name)) }
          return [base, override].compact.flat_map { |name| ["-f", File.join(directory, name)] }
        end
        parent = File.dirname(directory)
        raise ArgumentError, "No Compose file found; select it with compose_options: [\"-f\", path]" if parent == directory
        directory = parent
      end
    end

    def discovery_directory
      @compose_options.each_with_index do |option, index|
        return File.expand_path(@compose_options.fetch(index + 1), @project_root) if option == "--project-directory"
        return File.expand_path(option.delete_prefix("--project-directory="), @project_root) if option.start_with?("--project-directory=")
      end
      @project_root
    end
  end
end
