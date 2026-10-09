# frozen_string_literal: true

require "digest"
require "json"
require "shellwords"
require "tmpdir"

class OpenInEditorBridge
  class Configuration
    PROTOCOL = 2

    attr_reader :port, :bind_address, :connect_address, :runtime_directory, :startup_timeout, :session_id

    def initialize(env:, project_root: nil)
      @env = env
      @project_root = File.expand_path(project_root || env.fetch("OPEN_IN_EDITOR_PROJECT_ROOT", Dir.pwd))
      @project_root = File.realpath(@project_root) if File.directory?(@project_root)
      @port = Integer(env.fetch("OPEN_IN_EDITOR_BRIDGE_PORT", "3333"))
      @bind_address = env.fetch("OPEN_IN_EDITOR_BRIDGE_BIND_ADDRESS", "127.0.0.1")
      @connect_address = { "0.0.0.0" => "127.0.0.1", "::" => "::1" }.fetch(@bind_address, @bind_address)
      @runtime_directory = env.fetch("OPEN_IN_EDITOR_BRIDGE_RUNTIME_DIR", File.join(Dir.tmpdir, "open-in-editor-bridge-#{Process.uid}"))
      @startup_timeout = Float(env.fetch("OPEN_IN_EDITOR_BRIDGE_STARTUP_TIMEOUT", "5"))
      @session_id = Digest::SHA256.hexdigest(@project_root)
    end

    def session
      command = @env.fetch("OPEN_IN_EDITOR_COMMAND", @env.fetch("EDITOR", "")).to_s
      raise ArgumentError, "No editor configured. Set OPEN_IN_EDITOR_COMMAND or EDITOR." if Shellwords.split(command).empty?

      {
        "id" => session_id,
        "working_directory" => @project_root,
        "container_root" => @env.fetch("OPEN_IN_EDITOR_CONTAINER_WEB_ROOT", "/usr/src/web").delete_suffix("/"),
        "host_root" => File.expand_path(@env.fetch("OPEN_IN_EDITOR_HOST_WEB_ROOT", File.join(@project_root, "web"))),
        "editor_command" => command,
      }
    end

    def state_file
      File.join(runtime_directory, "#{port}.json")
    end

    def log_file
      File.join(runtime_directory, "#{port}.log")
    end

    def synchronize
      ensure_runtime_directory
      File.open(File.join(runtime_directory, "#{port}.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    end

    def ensure_runtime_directory
      begin
        Dir.mkdir(runtime_directory, 0o700)
      rescue Errno::EEXIST
        # Shared by all checkout clients of this user.
      end
      stat = File.lstat(runtime_directory)
      unless stat.directory? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
        raise StartupError, "Bridge runtime directory must be owned by this user and private (0700): #{runtime_directory}"
      end
    end

    def read_state
      state = JSON.parse(File.read(state_file))
      state if state.is_a?(Hash)
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    def write_state(token)
      state = { "pid" => Process.pid, "token" => token, "protocol" => PROTOCOL, "bind_address" => bind_address }
      File.open(state_file, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(state)) }
    end

    def delete_state(expected_pid:)
      File.delete(state_file) if read_state&.fetch("pid", nil) == expected_pid
    rescue Errno::ENOENT
      nil
    end

    def server_environment(token)
      {
        "OPEN_IN_EDITOR_BRIDGE_PORT" => port.to_s,
        "OPEN_IN_EDITOR_BRIDGE_BIND_ADDRESS" => bind_address,
        "OPEN_IN_EDITOR_BRIDGE_RUNTIME_DIR" => runtime_directory,
        "OPEN_IN_EDITOR_BRIDGE_CONTROL_TOKEN" => token,
      }
    end
  end
end
