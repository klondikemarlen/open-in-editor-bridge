# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "shellwords"
require "socket"
require "timeout"
require "uri"
require_relative "open_in_editor_bridge/version"

class OpenInEditorBridge
  DEFAULT_PORT = 3333
  HEALTH_PATH = "/health"
  OPEN_IN_EDITOR_PATH = "/__open-in-editor"
  RESPONSE_PHRASES = {
    200 => "OK",
    400 => "Bad Request",
    404 => "Not Found",
    405 => "Method Not Allowed",
    500 => "Internal Server Error",
  }.freeze

  class StartupError < StandardError
  end

  def self.call(*args)
    new.call(*args)
  end

  def self.with_running(ensure_running: true)
    owns_server = !ensure_running
    owns_server = call("--ensure-running") == :started if ensure_running

    begin
      yield
    ensure
      if owns_server
        block_error = $!
        begin
          call("--shutdown")
        rescue StandardError => cleanup_error
          raise cleanup_error unless block_error
        end
      end
    end
  end

  def initialize(env: ENV, project_root: nil)
    @env = env
    @project_root = project_root
  end

  def call(*args)
    case args.first || "--serve"
    when "--ensure-running"
      ensure_running
    when "--shutdown"
      shutdown
    when "--serve"
      serve
    else
      serve
    end
  end

  private

  def ensure_running
    pid = running_pid(validate_health: true)
    if pid
      puts "Editor bridge already running on port #{config[:port]} (pid #{pid})."
      return :reused
    end

    ensure_runtime_directory
    pid = Process.spawn(
      *server_process_command,
      out: config[:log_file],
      err: config[:log_file],
      pgroup: true
    )
    Process.detach(pid)

    wait_until_ready(pid)
    write_pid_file(pid)
    puts "Started editor bridge on port #{config[:port]}."
    :started
  rescue StandardError
    if pid && process_running?(pid)
      begin
        Process.kill("TERM", -pid)
      rescue Errno::ESRCH
      end
    end
    delete_pid_file
    raise
  end

  def shutdown
    pid = running_pid
    return unless pid

    Process.kill("TERM", -pid)
    wait_until_stopped(pid)
    delete_pid_file
    puts "Stopped editor bridge."
  rescue Errno::ESRCH
    delete_pid_file
  end

  def serve
    abort("No editor configured. Set OPEN_IN_EDITOR_COMMAND or EDITOR environment variable.") if editor_command.empty?

    ensure_runtime_directory
    write_pid_file(Process.pid)
    @server = TCPServer.new("127.0.0.1", config[:port])
    @running = true
    install_signal_handlers

    while @running
      begin
        socket = @server.accept
        handle_request(socket)
      rescue IOError, Errno::EBADF
        break
      end
    end
  ensure
    @server&.close
    delete_pid_file
  end

  def handle_request(socket)
    request = read_request(socket)
    return if request.nil?

    method = request.fetch(:method)
    consume_headers(socket)
    return write_json_response(socket, status: 405, payload: { error: "Method not allowed" }) unless method == "GET"

    respond_to_get_request(socket, request.fetch(:path), request.fetch(:params))
  ensure
    socket.close unless socket.closed?
  end

  def open_in_editor(socket, params)
    file = params["file"]
    if file.nil? || file.empty?
      return write_json_response(
        socket,
        status: 400,
        payload: { error: "Missing required query parameter: file" }
      )
    end

    translated_target = translate_target(file)
    pid = Process.spawn(*editor_command_args, "--goto", translated_target)
    Process.detach(pid)

    write_json_response(
      socket,
      status: 200,
      payload: {
        ok: true,
        requestedFile: file,
        translatedTarget: translated_target,
        editorCommand: editor_command,
      }
    )
  rescue StandardError => error
    write_json_response(
      socket,
      status: 500,
      payload: {
        ok: false,
        error: "Failed to open editor: #{error.message}",
        requestedFile: file,
        translatedTarget: translated_target,
        editorCommand: editor_command,
      }
    )
  end

  def write_json_response(socket, status: 200, payload:)
    body = JSON.generate(payload)
    socket.write("HTTP/1.1 #{status} #{RESPONSE_PHRASES.fetch(status)}\r\n")
    socket.write("Content-Type: application/json\r\n")
    socket.write("Access-Control-Allow-Origin: *\r\n")
    socket.write("X-Open-In-Editor-Bridge: 1\r\n")
    socket.write("Content-Length: #{body.bytesize}\r\n")
    socket.write("Connection: close\r\n")
    socket.write("\r\n")
    socket.write(body)
  end

  def stop_server
    @running = false
    @server&.close
  end

  def ensure_runtime_directory
    FileUtils.mkdir_p(File.dirname(config[:pid_file]))
  end

  def write_pid_file(pid)
    File.write(config[:pid_file], "#{pid}\n")
  end

  def delete_pid_file
    File.delete(config[:pid_file]) if File.exist?(config[:pid_file])
  end

  def server_process_command
    [RbConfig.ruby, File.expand_path("../exe/open-in-editor-bridge", __dir__), "--serve"]
  end

  def editor_command
    @env.fetch("OPEN_IN_EDITOR_COMMAND", @env.fetch("EDITOR", "")).to_s
  end

  def editor_command_args
    Shellwords.split(editor_command)
  end

  def install_signal_handlers
    trap("INT") { stop_server }
    trap("TERM") { stop_server }
  end

  def read_request(socket)
    request_line = socket.gets
    return nil if request_line.nil?

    method, raw_target, = request_line.split(" ")
    return nil if method.nil? || raw_target.nil?

    path, query = raw_target.split("?", 2)
    params = URI.decode_www_form(query.to_s).to_h
    { method: method, path: path, params: params }
  rescue ArgumentError
    write_json_response(socket, status: 400, payload: { error: "Bad request" })
    nil
  end

  def consume_headers(socket)
    loop do
      line = socket.gets
      break if line.nil? || line == "\r\n"
    end
  end

  def respond_to_get_request(socket, path, params)
    case path
    when HEALTH_PATH
      write_json_response(socket, payload: { ok: true })
    when OPEN_IN_EDITOR_PATH
      open_in_editor(socket, params)
    else
      write_json_response(socket, status: 404, payload: { error: "Not found" })
    end
  end

  def translate_target(target)
    path, location = split_target(target)
    translated_path = path.sub(/\A#{Regexp.escape(config[:container_web_root])}/, config[:host_web_root])
    return translated_path if location.nil?

    "#{translated_path}:#{location}"
  end

  def split_target(target)
    decoded_target = URI.decode_www_form_component(target)
    match = decoded_target.match(/\A(.+?):(\d+)(?::(\d+))?\z/)
    return [decoded_target, nil] if match.nil?

    [match[1], [match[2], match[3]].compact.join(":")]
  end

  def running_pid(validate_health: false)
    return nil unless File.exist?(config[:pid_file])

    pid = Integer(File.read(config[:pid_file]).strip)
    return pid if process_running?(pid) && (!validate_health || bridge_healthy?)

    delete_pid_file
    nil
  rescue ArgumentError
    delete_pid_file
    nil
  end

  def process_running?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def wait_until_ready(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + config[:startup_timeout]
    loop do
      raise StartupError, "Editor bridge failed to start. See #{config[:log_file]}." unless process_running?(pid)
      return if bridge_healthy?

      raise StartupError, "Editor bridge did not become ready." if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.05
    end
  end

  def wait_until_stopped(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + config[:startup_timeout]
    until !process_running?(pid) && !bridge_healthy?
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
  end

  def bridge_healthy?
    socket = TCPSocket.new("127.0.0.1", config[:port])
    response = Timeout.timeout(0.25) do
      socket.write("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
      socket.read
    end
    headers, body = response.split("\r\n\r\n", 2)
    headers&.start_with?("HTTP/1.1 200 ") &&
      headers.lines.any? { |line| line.casecmp("X-Open-In-Editor-Bridge: 1\r\n").zero? } &&
      JSON.parse(body.to_s).fetch("ok") == true
  rescue Errno::ECONNREFUSED, JSON::ParserError, KeyError, Timeout::Error
    false
  ensure
    socket&.close unless socket&.closed?
  end

  def config
    root = @project_root || @env.fetch("OPEN_IN_EDITOR_PROJECT_ROOT", Dir.pwd)
    {
      port: Integer(@env.fetch("OPEN_IN_EDITOR_BRIDGE_PORT", DEFAULT_PORT)),
      pid_file: File.join(root, "tmp", "open-in-editor-bridge.pid"),
      log_file: File.join(root, "tmp", "open-in-editor-bridge.log"),
      container_web_root: @env.fetch("OPEN_IN_EDITOR_CONTAINER_WEB_ROOT", "/usr/src/web"),
      host_web_root: @env.fetch("OPEN_IN_EDITOR_HOST_WEB_ROOT", File.join(root, "web")),
      startup_timeout: Float(@env.fetch("OPEN_IN_EDITOR_BRIDGE_STARTUP_TIMEOUT", "5")),
    }
  end
end

OpenInEditorBridge.call(*ARGV) if $PROGRAM_NAME == __FILE__
