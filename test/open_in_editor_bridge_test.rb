# frozen_string_literal: true

require "minitest/autorun"
require "net/http"
require "rbconfig"
require "tmpdir"
require "uri"
require_relative "../lib/open_in_editor_bridge"

class OpenInEditorBridgeTest < Minitest::Test
  def setup
    @project_root = Dir.mktmpdir("open-in-editor-bridge")
    @env = {
      "OPEN_IN_EDITOR_BRIDGE_PORT" => free_port.to_s,
      "OPEN_IN_EDITOR_PROJECT_ROOT" => @project_root,
      "OPEN_IN_EDITOR_COMMAND" => "#{RbConfig.ruby} -e 'exit'",
    }
    @previous_environment = @env.keys.to_h { |key| [key, ENV[key]] }
    @env.each { |key, value| ENV[key] = value }
  end

  def teardown
    bridge.call("--shutdown")
  rescue StandardError
    nil
  ensure
    @previous_environment.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    FileUtils.remove_entry(@project_root) if @project_root && File.exist?(@project_root)
  end

  def test_with_running_returns_the_block_result_and_removes_pid_file
    result = OpenInEditorBridge.with_running { :result }

    assert_equal :result, result
    refute File.exist?(pid_file)
    refute port_open?
  end

  def test_with_running_preserves_block_exception_and_cleans_up
    error = assert_raises(RuntimeError) do
      OpenInEditorBridge.with_running { raise "block failed" }
    end

    assert_equal "block failed", error.message
    refute File.exist?(pid_file)
  end

  def test_with_running_does_not_stop_a_reused_bridge
    bridge.call("--ensure-running")

    OpenInEditorBridge.with_running { :result }

    assert bridge_running?
  end

  def test_health_endpoint
    bridge.call("--ensure-running")

    response = request("/health")

    assert_equal "200", response.code
    payload = JSON.parse(response.body)
    assert_equal true, payload.fetch("ok")
    assert_equal Integer(File.read(pid_file)), payload.fetch("pid")
  end

  def test_open_in_editor_translates_path_and_location
    bridge.call("--ensure-running")
    file = URI.encode_www_form_component("/usr/src/web/app.rb:12:4")

    response = request("/__open-in-editor?file=#{file}")
    payload = JSON.parse(response.body)

    assert_equal "200", response.code
    assert_equal File.join(@project_root, "web/app.rb:12:4"), payload.fetch("translatedTarget")
  end

  def test_open_in_editor_requires_a_file
    bridge.call("--ensure-running")

    response = request("/__open-in-editor")

    assert_equal "400", response.code
    assert_equal "Missing required query parameter: file", JSON.parse(response.body).fetch("error")
  end

  def test_unknown_path_and_non_get_requests_are_rejected
    bridge.call("--ensure-running")

    not_found = request("/unknown")
    method_not_allowed = request("/health", Net::HTTP::Post)

    assert_equal "404", not_found.code
    assert_equal "405", method_not_allowed.code
  end

  def test_startup_fails_when_the_configured_port_is_occupied
    listener = TCPServer.new("127.0.0.1", @env.fetch("OPEN_IN_EDITOR_BRIDGE_PORT").to_i)
    @env["OPEN_IN_EDITOR_BRIDGE_STARTUP_TIMEOUT"] = "0.5"

    assert_raises(OpenInEditorBridge::StartupError) { bridge.call("--ensure-running") }
  ensure
    listener&.close
  end

  def test_shutdown_removes_stale_pid_without_killing_unrelated_process
    unrelated_pid = Process.spawn(RbConfig.ruby, "-e", "sleep 10", pgroup: true)
    FileUtils.mkdir_p(File.dirname(pid_file))
    File.write(pid_file, "#{unrelated_pid}\n")

    bridge.call("--shutdown")

    assert_process_running(unrelated_pid)
    refute File.exist?(pid_file)
  ensure
    if unrelated_pid
      Process.kill("TERM", -unrelated_pid) rescue Errno::ESRCH
      Process.wait(unrelated_pid) rescue Errno::ECHILD
    end
  end

  def test_shutdown_does_not_kill_stale_pid_when_another_bridge_answers
    bridge.call("--ensure-running")
    bridge_pid = Integer(File.read(pid_file))
    unrelated_pid = Process.spawn(RbConfig.ruby, "-e", "sleep 10", pgroup: true)
    File.write(pid_file, "#{unrelated_pid}\n")

    bridge.call("--shutdown")

    assert_process_running(unrelated_pid)
    assert_equal "200", request("/health").code
  ensure
    if bridge_pid
      File.write(pid_file, "#{bridge_pid}\n")
      bridge.call("--shutdown")
    end
    if unrelated_pid
      Process.kill("TERM", -unrelated_pid) rescue Errno::ESRCH
      Process.wait(unrelated_pid) rescue Errno::ECHILD
    end
  end

  private

  def bridge
    @bridge ||= OpenInEditorBridge.new(env: @env, project_root: @project_root)
  end

  def pid_file
    File.join(@project_root, "tmp", "open-in-editor-bridge.pid")
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr.fetch(1)
  ensure
    server&.close
  end

  def bridge_running?
    Process.kill(0, Integer(File.read(pid_file)))
    true
  rescue Errno::ESRCH, Errno::ENOENT
    false
  end

  def assert_process_running(pid)
    Process.kill(0, pid)
  rescue Errno::ESRCH, Errno::EPERM
    flunk "expected process #{pid} to remain running"
  end

  def port_open?
    socket = TCPSocket.new("127.0.0.1", @env.fetch("OPEN_IN_EDITOR_BRIDGE_PORT"))
    true
  rescue Errno::ECONNREFUSED
    false
  ensure
    socket&.close
  end

  def request(path, request_class = Net::HTTP::Get)
    uri = URI("http://127.0.0.1:#{@env.fetch("OPEN_IN_EDITOR_BRIDGE_PORT")}#{path}")
    request = request_class.new(uri)
    Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
  end
end
