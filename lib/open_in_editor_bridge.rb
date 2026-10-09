# frozen_string_literal: true

require_relative "open_in_editor_bridge/version"

class OpenInEditorBridge
  class StartupError < StandardError
  end

  def self.call(*args)
    new.call(*args)
  end

  def self.session_id
    new.session_id
  end

  def self.with_running(ensure_running: true)
    bridge = new
    lease = SecureRandom.hex(16) if ensure_running
    bridge.start_session(lease) if ensure_running

    begin
      yield bridge.session_id
    ensure
      block_error = $!
      begin
        ensure_running ? bridge.stop_session(lease) : bridge.call("--shutdown")
      rescue StandardError => cleanup_error
        raise cleanup_error unless block_error
      end
    end
  end

  def initialize(env: ENV, project_root: nil)
    @configuration = Configuration.new(env: env, project_root: project_root)
    @client = Client.new(@configuration)
  end

  def session_id
    @configuration.session_id
  end

  def call(*args)
    case args.first || "--serve"
    when "--ensure-running"
      start_session("detached")
    when "--shutdown"
      stop_session("detached")
    when "--session-id"
      puts session_id
      session_id
    when "--serve"
      @client.serve
    else
      raise ArgumentError, "Unknown command: #{args.first}"
    end
  end

  def start_session(lease)
    @client.register(lease)
  end

  def stop_session(lease)
    @client.release(lease)
  end
end

require_relative "open_in_editor_bridge/configuration"
require_relative "open_in_editor_bridge/authentication"
require_relative "open_in_editor_bridge/server"
require_relative "open_in_editor_bridge/client"

OpenInEditorBridge.call(*ARGV) if $PROGRAM_NAME == __FILE__
