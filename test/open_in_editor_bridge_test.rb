# frozen_string_literal: true

require "fileutils"
require "net/http"
require "rbconfig"
require "tmpdir"
require "uri"

require "minitest/autorun"

require_relative "../lib/open_in_editor_bridge"

class OpenInEditorBridgeTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("open-in-editor-bridge-test")
    @project_root = File.join(@directory, "checkout-a")
    FileUtils.mkdir_p(@project_root)
    @runtime_directory = File.join(@directory, "runtime")
    @port = free_port
    @env = {
      "OPEN_IN_EDITOR_BRIDGE_PORT" => @port.to_s,
      "OPEN_IN_EDITOR_PROJECT_ROOT" => @project_root,
      "OPEN_IN_EDITOR_BRIDGE_RUNTIME_DIR" => @runtime_directory,
      "OPEN_IN_EDITOR_COMMAND" => "#{RbConfig.ruby} -e 'exit' --",
    }
    @previous_environment = @env.keys.to_h { |key| [key, ENV[key]] }
    @env.each { |key, value| ENV[key] = value }
    @bridges = []
  end

  def teardown
    @bridges.each { |client| client.call("--shutdown") }
  ensure
    @previous_environment.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    FileUtils.remove_entry(@directory)
  end

  def test_with_running_returns_block_result_and_releases_its_session
    result = OpenInEditorBridge.with_running do |session_id|
      assert_equal bridge.session_id, session_id
      assert_equal [session_id], health.fetch("sessions")
      :result
    end

    assert_equal :result, result
    refute File.exist?(state_file)
    refute port_open?
  end

  def test_with_running_preserves_block_exception_and_cleans_up
    error = assert_raises(RuntimeError) do
      OpenInEditorBridge.with_running { raise "block failed" }
    end

    assert_equal "block failed", error.message
    refute port_open?
  end

  def test_foreground_wrapper_keeps_detached_registration_alive
    bridge.call("--ensure-running")
    pid = health.fetch("pid")

    OpenInEditorBridge.with_running { :result }

    assert_equal pid, health.fetch("pid")
    assert_equal :reused, bridge.call("--ensure-running")
    bridge.call("--shutdown")
    refute port_open?
  end

  def test_overlapping_foreground_clients_keep_their_own_leases
    first = bridge
    second = build_bridge(@env)
    first.start_session("foreground-a")
    second.start_session("foreground-b")
    first.stop_session("foreground-a")

    assert_equal [first.session_id], health.fetch("sessions")
    second.stop_session("foreground-b")
    refute port_open?
  end

  def test_shutdown_only_wrapper_releases_detached_session
    bridge.call("--ensure-running")

    OpenInEditorBridge.with_running(ensure_running: false) { :down }

    refute port_open?
  end

  def test_two_checkouts_route_to_their_own_host_files_and_editor_commands
    first_output = File.join(@directory, "editor-a.json")
    second_output = File.join(@directory, "editor-b.json")
    first = build_bridge(@env.merge("OPEN_IN_EDITOR_COMMAND" => recording_editor(first_output)))
    second = second_checkout("OPEN_IN_EDITOR_COMMAND" => recording_editor(second_output))
    first.call("--ensure-running")
    second.call("--ensure-running")
    pid = health.fetch("pid")

    first_response = editor_request("/usr/src/web/app%20name.rb:12:4", first.session_id)
    second_response = editor_request("/usr/src/web/app.rb:98:1", second.session_id)

    assert_equal "200", first_response.code
    assert_equal "200", second_response.code
    assert_equal ["--goto", File.join(@project_root, "web/app%20name.rb:12:4")], recorded_arguments(first_output)
    assert_equal ["--goto", File.join(@directory, "checkout-b/web/app.rb:98:1")], recorded_arguments(second_output)
    first.call("--shutdown")
    assert_equal pid, health.fetch("pid")
    assert_equal "404", editor_request("/usr/src/web/app.rb", first.session_id).code
    assert_equal "200", editor_request("/usr/src/web/app.rb", second.session_id).code
    second.call("--shutdown")
    refute port_open?
    refute File.exist?(state_file)
  end

  def test_simultaneous_checkout_starts_share_one_broker
    clients = [bridge, second_checkout]
    gate = Queue.new
    processes = clients.map do |client|
      Thread.new { gate.pop; client.call("--ensure-running") }
    end
    clients.each { gate << true }
    assert_equal [:started, :started], processes.map(&:value)

    assert_equal clients.map(&:session_id).sort, health.fetch("sessions").sort
    assert_equal state.fetch("pid"), health.fetch("pid")
  end

  def test_multiple_checkouts_reject_ambiguous_and_unknown_sessions
    bridge.call("--ensure-running")
    second_checkout.call("--ensure-running")

    assert_equal "400", editor_request("/usr/src/web/app.rb").code
    assert_equal "404", editor_request("/usr/src/web/app.rb", "missing-session").code
  end

  def test_single_checkout_accepts_links_without_session_and_preserves_location
    bridge.call("--ensure-running")

    response = editor_request("/usr/src/web/app.rb:12:4")

    assert_equal "200", response.code
    assert_equal File.join(@project_root, "web/app.rb:12:4"), JSON.parse(response.body).fetch("translatedTarget")
  end

  def test_path_mapping_requires_a_directory_boundary
    bridge.call("--ensure-running")

    response = editor_request("/usr/src/website/app.rb:3")

    assert_equal "/usr/src/website/app.rb:3", JSON.parse(response.body).fetch("translatedTarget")
  end

  def test_missing_file_unknown_path_and_unsupported_method
    bridge.call("--ensure-running")

    assert_equal "400", request("/__open-in-editor").code
    assert_equal "404", request("/unknown").code
    assert_equal "405", request("/health", Net::HTTP::Post).code
  end

  def test_unauthenticated_lifecycle_control_cannot_release_a_checkout
    bridge.call("--ensure-running")
    uri = URI("http://127.0.0.1:#{@port}/release")
    post = Net::HTTP::Post.new(uri)
    post.body = JSON.generate("session_id" => bridge.session_id, "lease" => "detached")

    response = Net::HTTP.start(uri.hostname, uri.port, nil) { |http| http.request(post) }

    assert_equal "403", response.code
    assert_equal [bridge.session_id], health.fetch("sessions")
  end

  def test_conflicting_checkout_configuration_does_not_replace_an_active_mapping
    bridge.call("--ensure-running")
    conflicting = build_bridge(@env.merge("OPEN_IN_EDITOR_HOST_WEB_ROOT" => "/wrong-checkout/web"))

    assert_raises(OpenInEditorBridge::StartupError) { conflicting.call("--ensure-running") }
    response = editor_request("/usr/src/web/app.rb")
    assert_equal File.join(@project_root, "web/app.rb"), JSON.parse(response.body).fetch("translatedTarget")
  end

  def test_non_bridge_listener_is_not_reused_or_signaled
    listener = TCPServer.new("127.0.0.1", @port)
    responder = Thread.new do
      loop do
        socket = listener.accept
        socket.gets
        socket.write("HTTP/1.1 200 OK\r\nX-Open-In-Editor-Bridge: 2\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]")
        socket.close
      end
    rescue IOError, Errno::EBADF
      nil
    end

    assert_raises(OpenInEditorBridge::StartupError) { bridge.call("--ensure-running") }
    assert_equal "200", request("/health").code
  ensure
    listener&.close
    responder&.join
  end

  def test_shutdown_discards_stale_state_without_killing_an_unrelated_process
    unrelated_pid = Process.spawn(RbConfig.ruby, "-e", "sleep 10", pgroup: true)
    FileUtils.mkdir_p(@runtime_directory, mode: 0o700)
    File.write(state_file, JSON.generate("pid" => unrelated_pid, "token" => "stale", "protocol" => 2))

    bridge.call("--shutdown")

    assert_process_running(unrelated_pid)
    refute File.exist?(state_file)
  ensure
    terminate_child(unrelated_pid)
  end

  def test_shutdown_rejects_mismatched_pid_when_another_bridge_answers
    bridge.call("--ensure-running")
    original_state = state
    unrelated_pid = Process.spawn(RbConfig.ruby, "-e", "sleep 10", pgroup: true)
    File.write(state_file, JSON.generate(original_state.merge("pid" => unrelated_pid)))

    assert_raises(OpenInEditorBridge::StartupError) { bridge.call("--shutdown") }

    assert_process_running(unrelated_pid)
    assert_equal original_state.fetch("pid"), health.fetch("pid")
  ensure
    File.write(state_file, JSON.generate(original_state)) if original_state
    terminate_child(unrelated_pid)
  end

  def test_incomplete_http_request_does_not_destroy_live_broker_state
    bridge.call("--ensure-running")
    original_state = state
    stalled_socket = TCPSocket.new("127.0.0.1", @port)
    stalled_socket.write("GET /health HTTP/1.1\r\n")

    assert_raises(OpenInEditorBridge::StartupError) { bridge.call("--shutdown") }

    assert_equal original_state, state
    stalled_socket.close
    assert_equal original_state.fetch("pid"), health.fetch("pid")
  ensure
    stalled_socket&.close unless stalled_socket&.closed?
  end

  def test_relative_editor_commands_execute_in_the_requesting_checkout
    first = build_bridge(@env.merge("OPEN_IN_EDITOR_COMMAND" => "./editor"))
    second = second_checkout("OPEN_IN_EDITOR_COMMAND" => "./editor")
    [@project_root, File.join(@directory, "checkout-b")].each do |root|
      editor = File.join(root, "editor")
      File.write(editor, "#!#{RbConfig.ruby}\nrequire 'json'\nFile.write('editor.json', JSON.generate(ARGV))\n")
      File.chmod(0o755, editor)
    end
    first.call("--ensure-running")
    second.call("--ensure-running")

    assert_equal "200", editor_request("/usr/src/web/a.rb:3:2", first.session_id).code
    assert_equal "200", editor_request("/usr/src/web/b.rb:8:1", second.session_id).code
    assert_equal ["--goto", File.join(@project_root, "web/a.rb:3:2")], recorded_arguments(File.join(@project_root, "editor.json"))
    assert_equal ["--goto", File.join(@directory, "checkout-b/web/b.rb:8:1")],
      recorded_arguments(File.join(@directory, "checkout-b/editor.json"))
  end

  def test_counterfeit_health_cannot_disclose_control_credentials
    with_impostor_listener(sign_health: false) do |requests, original_state|
      assert_raises(OpenInEditorBridge::StartupError) { bridge.call("--ensure-running") }

      assert_equal original_state, state
      assert_equal ["GET /health HTTP/1.1"], requests.map { |raw| raw.lines.first.strip }
      refute_includes requests.join, original_state.fetch("token")
    end
  end

  def test_fabricated_control_success_is_rejected_after_authenticated_health
    with_impostor_listener(sign_health: true) do |requests, original_state|
      assert_raises(OpenInEditorBridge::StartupError) { bridge.call("--ensure-running") }

      assert_equal ["GET /health HTTP/1.1", "POST /sessions HTTP/1.1"],
        requests.map { |raw| raw.lines.first.strip }
      refute_includes requests.join, original_state.fetch("token")
    end
  end

  def test_replayed_shutdown_cannot_release_a_new_detached_registration
    bridge.call("--ensure-running")
    second = second_checkout
    second.call("--ensure-running")
    token = state.fetch("token")
    nonce = SecureRandom.hex(16)
    post = Net::HTTP::Post.new("/release")
    post["Content-Type"] = "application/json"
    post["X-Open-In-Editor-Nonce"] = nonce
    post.body = JSON.generate("session_id" => bridge.session_id, "lease" => "detached")
    post["X-Open-In-Editor-Signature"] = OpenInEditorBridge::Authentication.signature(token,
      "request", nonce, "POST", "/release", post.body)

    first_response = Net::HTTP.start("127.0.0.1", @port, nil) { |http| http.request(post) }
    assert_equal "200", first_response.code
    bridge.call("--ensure-running")
    replayed_response = Net::HTTP.start("127.0.0.1", @port, nil) { |http| http.request(post) }

    assert_equal "403", replayed_response.code
    assert_equal [bridge.session_id, second.session_id].sort, health.fetch("sessions").sort
  end

  def test_invalid_utf8_health_nonce_does_not_stop_registered_checkouts
    bridge.call("--ensure-running")
    second = second_checkout
    second.call("--ensure-running")
    original_state = state

    response = raw_request("GET /health HTTP/1.1\r\nX-Open-In-Editor-Nonce: \xff\r\n\r\n".b)

    assert response.start_with?("HTTP/1.1 400 ")
    assert_equal original_state, state
    assert_equal [bridge.session_id, second.session_id].sort, health.fetch("sessions").sort
  end

  def test_invalid_utf8_control_body_does_not_stop_registered_checkouts
    bridge.call("--ensure-running")
    second = second_checkout
    second.call("--ensure-running")
    original_state = state
    message = "POST /sessions HTTP/1.1\r\nContent-Length: 1\r\n" \
      "X-Open-In-Editor-Nonce: #{'0' * 32}\r\nX-Open-In-Editor-Signature: #{'0' * 64}\r\n\r\n\xff"

    response = raw_request(message.b)

    assert response.start_with?("HTTP/1.1 403 ")
    assert_equal original_state, state
    assert_equal [bridge.session_id, second.session_id].sort, health.fetch("sessions").sort
  end

  def test_compose_foreground_releases_its_lease_after_success_and_failure
    compose_fixture(exit_status: 0)
    assert OpenInEditorBridge.compose("up", env: docker_env)
    refute port_open?

    compose_fixture(exit_status: 17)
    assert_raises(RuntimeError) { OpenInEditorBridge.compose("up", env: docker_env) }
    refute port_open?
  end

  def test_compose_detached_registration_is_idempotent_and_down_releases_it
    compose_fixture(exit_status: 0)
    OpenInEditorBridge.compose("up", "-d", env: docker_env)
    client = build_bridge(docker_env)
    pid = health.fetch("pid")
    OpenInEditorBridge.compose("up", "--detach", env: docker_env)

    assert_equal pid, health.fetch("pid")
    assert_equal [client.session_id], health.fetch("sessions")
    OpenInEditorBridge.compose("down", env: docker_env)
    refute port_open?
  end

  def test_failed_detached_compose_start_releases_only_new_registration
    compose_fixture(exit_status: 17)
    assert_raises(RuntimeError) { OpenInEditorBridge.compose("up", "-d", env: docker_env) }
    refute port_open?

    client = build_bridge(docker_env)
    client.call("--ensure-running")
    pid = health.fetch("pid")
    assert_raises(RuntimeError) { OpenInEditorBridge.compose("up", "-d", env: docker_env) }

    assert_equal pid, health.fetch("pid")
    assert_equal [client.session_id], health.fetch("sessions")
  end

  def test_failed_compose_down_keeps_the_application_registration
    compose_fixture(exit_status: 0)
    OpenInEditorBridge.compose("up", "-d", env: docker_env)
    client = build_bridge(docker_env)
    compose_fixture(exit_status: 17)

    assert_raises(RuntimeError) { OpenInEditorBridge.compose("down", env: docker_env) }

    assert_equal [client.session_id], health.fetch("sessions")
  end

  def test_unrelated_compose_commands_do_not_require_valid_editor_configuration
    compose_fixture(exit_status: 0)
    env = docker_env.merge("OPEN_IN_EDITOR_COMMAND" => "", "OPEN_IN_EDITOR_BRIDGE_PORT" => "not-a-port")

    assert OpenInEditorBridge.compose("config", env: env)
    refute File.exist?(@runtime_directory)
    refute port_open?
  end

  def test_compose_requires_docker_network_opt_in_before_registering
    compose_fixture(exit_status: 0)
    env = docker_env.merge("OPEN_IN_EDITOR_BRIDGE_BIND_ADDRESS" => "127.0.0.1")

    assert_raises(ArgumentError) { OpenInEditorBridge.compose("up", "-d", env: env) }

    refute File.exist?(@runtime_directory)
    refute port_open?
  end

  private

  def docker_env
    @env.merge("PATH" => "#{File.join(@directory, "bin")}:#{ENV.fetch("PATH")}",
      "OPEN_IN_EDITOR_BRIDGE_BIND_ADDRESS" => "0.0.0.0")
  end

  def compose_fixture(exit_status:)
    FileUtils.mkdir_p(File.join(@directory, "bin"))
    File.write(File.join(@project_root, "compose.yaml"), "services:\n  web:\n    image: unused\n")
    command = File.join(@directory, "bin/docker")
    File.write(command, "#!/bin/sh\nexit #{exit_status}\n")
    File.chmod(0o755, command)
  end

  def bridge
    @bridge ||= build_bridge(@env)
  end

  def build_bridge(env)
    client = OpenInEditorBridge.new(env: env)
    @bridges << client
    client
  end

  def second_checkout(overrides = {})
    root = File.join(@directory, "checkout-b")
    FileUtils.mkdir_p(root)
    build_bridge(@env.merge("OPEN_IN_EDITOR_PROJECT_ROOT" => root).merge(overrides))
  end

  def state_file
    File.join(@runtime_directory, "#{@port}.json")
  end

  def state
    JSON.parse(File.read(state_file))
  end

  def health
    JSON.parse(request("/health").body)
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr.fetch(1)
  ensure
    server&.close
  end

  def assert_process_running(pid)
    Process.kill(0, pid)
  rescue Errno::ESRCH, Errno::EPERM
    flunk "expected process #{pid} to remain running"
  end

  def terminate_child(pid)
    return unless pid
    Process.kill("TERM", pid) rescue Errno::ESRCH
    Process.wait(pid) rescue Errno::ECHILD
  end

  def port_open?
    socket = TCPSocket.new("127.0.0.1", @port)
    true
  rescue Errno::ECONNREFUSED
    false
  ensure
    socket&.close
  end

  def request(path, request_class = Net::HTTP::Get)
    uri = URI("http://127.0.0.1:#{@port}#{path}")
    Net::HTTP.start(uri.hostname, uri.port, nil) { |http| http.request(request_class.new(uri)) }
  end

  def raw_request(message)
    socket = TCPSocket.new("127.0.0.1", @port)
    socket.write(message)
    socket.read
  ensure
    socket&.close
  end

  def editor_request(file, session_id = nil)
    params = { "file" => file }
    params["session"] = session_id if session_id
    request("/__open-in-editor?#{URI.encode_www_form(params)}")
  end

  def with_impostor_listener(sign_health:)
    original_state = { "pid" => Process.pid, "token" => SecureRandom.hex(32),
      "protocol" => 2, "bind_address" => "127.0.0.1" }
    FileUtils.mkdir_p(@runtime_directory, mode: 0o700)
    File.write(state_file, JSON.generate(original_state))
    requests = []
    listener = TCPServer.new("127.0.0.1", @port)
    responder = Thread.new do
      loop do
        socket = listener.accept
        request_line = socket.gets
        unless request_line
          socket.close
          next
        end
        raw = request_line.dup
        headers = {}
        while (line = socket.gets) && line != "\r\n"
          raw << line
          name, value = line.split(":", 2)
          headers[name.downcase] = value.strip
        end
        raw << socket.read(Integer(headers.fetch("content-length", "0"))).to_s
        requests << raw
        path = request_line.split[1]
        payload = path == "/health" ?
          { "ok" => true, "pid" => Process.pid, "protocol" => 2, "bind_address" => "127.0.0.1" } :
          { "ok" => true, "added" => true }
        body = JSON.generate(payload)
        signature_header = ""
        if sign_health && path == "/health"
          signature = OpenInEditorBridge::Authentication.signature(original_state.fetch("token"),
            "response", headers.fetch("x-open-in-editor-nonce"), "200", path, body)
          signature_header = "X-Open-In-Editor-Signature: #{signature}\r\n"
        end
        socket.write("HTTP/1.1 200 OK\r\nX-Open-In-Editor-Bridge: 2\r\n#{signature_header}" \
          "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        socket.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    yield requests, original_state
  ensure
    listener&.close
    responder&.join
  end

  def recording_editor(output)
    script = "require 'json'; File.write(ARGV.shift, JSON.generate(ARGV))"
    Shellwords.join([RbConfig.ruby, "-e", script, "--", output])
  end

  def recorded_arguments(output)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until File.exist?(output)
      flunk "editor invocation not recorded" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
    JSON.parse(File.read(output))
  end
end
