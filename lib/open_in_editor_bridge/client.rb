# frozen_string_literal: true

require "net/http"
require "rbconfig"
require "securerandom"

class OpenInEditorBridge
  class Client
    def initialize(configuration)
      @configuration = configuration
    end

    def register(lease)
      session = @configuration.session
      @configuration.synchronize do
        state = compatible_state
        state ||= start_broker
        payload = control_request("/sessions", state, "session" => session, "lease" => lease)
        result = payload.fetch("added") ? :started : :reused
        puts "Editor session #{session.fetch("id")} #{result} on port #{@configuration.port}."
        result
      end
    end

    def release(lease)
      @configuration.synchronize do
        state = compatible_state
        return unless state

        payload = control_request("/release", state, "session_id" => @configuration.session_id, "lease" => lease)
        wait_until_stopped(state.fetch("pid")) if payload.fetch("stopping")
      end
    end

    def serve
      server = @configuration.synchronize do
        raise StartupError, "Editor bridge is already running" if compatible_state
        token = SecureRandom.hex(32)
        broker = Server.new(@configuration, token: token)
        broker.start(initial_session: @configuration.session)
        broker
      end
      server.serve
    end

    private

    def health(state: nil)
      nonce = SecureRandom.hex(16)
      request = Net::HTTP::Get.new("/health")
      request["X-Open-In-Editor-Nonce"] = nonce
      response = http_request(request)
      return nil unless response && response.code == "200" && response["X-Open-In-Editor-Bridge"] == Configuration::PROTOCOL.to_s
      if state
        return nil unless Authentication.valid?(response["X-Open-In-Editor-Signature"], state["token"],
          "response", nonce, response.code, "/health", response.body)
      end

      payload = JSON.parse(response.body)
      return nil unless payload.is_a?(Hash) && payload["ok"] == true && payload["protocol"] == Configuration::PROTOCOL
      payload
    rescue JSON::ParserError
      nil
    end

    def compatible_state
      state = @configuration.read_state
      current_health = health(state: state)
      if current_health
        unless state && state["pid"] == current_health["pid"] && state["protocol"] == Configuration::PROTOCOL &&
            state["bind_address"] == @configuration.bind_address && current_health["bind_address"] == @configuration.bind_address &&
            state["token"].is_a?(String) && !state["token"].empty?
          raise StartupError, "Listener identity or bind address does not match shared runtime state"
        end
        return state
      end
      if listener_present?
        raise StartupError, "Port is occupied by an unknown or unresponsive listener; shared state preserved"
      end
      if state
        # Never signal a PID read from disk. Only authenticated broker control can stop it.
        @configuration.delete_state(expected_pid: state["pid"])
      end
      nil
    end

    def listener_present?
      Socket.tcp(@configuration.connect_address, @configuration.port, connect_timeout: 0.5) { true }
    rescue Errno::ECONNREFUSED
      false
    rescue SystemCallError, Timeout::Error
      # An inconclusive connection failure is not proof that shared state is stale.
      true
    end

    def start_broker
      token = SecureRandom.hex(32)
      library_directory = File.expand_path("..", __dir__)
      script = "configuration = OpenInEditorBridge::Configuration.new(env: ENV); " \
        "server = OpenInEditorBridge::Server.new(configuration, token: ENV.fetch('OPEN_IN_EDITOR_BRIDGE_CONTROL_TOKEN')); " \
        "server.start; server.serve"
      pid = Process.spawn(@configuration.server_environment(token), RbConfig.ruby, "-I", library_directory,
        "-ropen_in_editor_bridge", "-e", script, out: @configuration.log_file, err: @configuration.log_file, pgroup: true)
      # Keep the child waitable until readiness proves we own this live PID.
      deadline = monotonic_time + @configuration.startup_timeout
      loop do
        raise StartupError, "Editor bridge failed to start. See #{@configuration.log_file}." if Process.waitpid(pid, Process::WNOHANG)
        state = @configuration.read_state
        current_health = health(state: state)
        if state && state["pid"] == pid && state["token"] == token && current_health && current_health["pid"] == pid
          Process.detach(pid)
          return state
        end
        raise StartupError, "Editor bridge did not become ready. See #{@configuration.log_file}." if monotonic_time >= deadline
        sleep 0.05
      end
    rescue StandardError
      if pid
        begin
          unless Process.waitpid(pid, Process::WNOHANG)
            Process.kill("TERM", pid)
            Process.waitpid(pid)
          end
        rescue Errno::ECHILD, Errno::ESRCH
          # An exited child is not a PID we still own.
        end
        @configuration.delete_state(expected_pid: pid)
      end
      raise
    end

    def control_request(path, state, payload)
      nonce = SecureRandom.hex(16)
      request = Net::HTTP::Post.new(path)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload)
      request["X-Open-In-Editor-Nonce"] = nonce
      request["X-Open-In-Editor-Signature"] = Authentication.signature(state.fetch("token"),
        "request", nonce, "POST", path, request.body)
      response = http_request(request)
      unless response && Authentication.valid?(response["X-Open-In-Editor-Signature"], state.fetch("token"),
          "response", nonce, response.code, path, response.body)
        raise StartupError, "Bridge control response failed authentication"
      end
      unless response && response.code == "200"
        raise StartupError, "Bridge session request failed: #{response&.code} #{response&.body}"
      end
      JSON.parse(response.body)
    end

    def http_request(request)
      Net::HTTP.start(@configuration.connect_address, @configuration.port, nil,
        open_timeout: 0.5, read_timeout: 0.5, write_timeout: 0.5) { |http| http.request(request) }
    rescue IOError, SystemCallError, Timeout::Error
      nil
    end

    def wait_until_stopped(pid)
      deadline = monotonic_time + @configuration.startup_timeout
      loop do
        state = @configuration.read_state
        return unless state && state["pid"] == pid
        raise StartupError, "Editor bridge did not stop" if monotonic_time >= deadline
        sleep 0.05
      end
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
