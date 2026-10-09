# frozen_string_literal: true

require "socket"
require "timeout"
require "uri"

class OpenInEditorBridge
  class Server
    RESPONSE_PHRASES = {
      200 => "OK", 400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found",
      405 => "Method Not Allowed", 409 => "Conflict", 500 => "Internal Server Error",
    }.freeze

    def initialize(configuration, token:)
      @configuration = configuration
      @token = token
      # Only this broker mutates sessions; each lease represents one live client.
      @sessions = {}
      # Accepted control nonces cannot be replayed during this broker's lifetime.
      @used_nonces = {}
    end

    def start(initial_session: nil)
      @listener = TCPServer.new(@configuration.bind_address, @configuration.port)
      @sessions[initial_session.fetch("id")] = initial_session.merge("leases" => ["detached"]) if initial_session
      @configuration.write_state(@token)
      @running = true
    rescue StandardError
      @listener&.close
      raise
    end

    def serve
      trap("INT") { stop }
      trap("TERM") { stop }
      while @running
        begin
          socket = @listener.accept
          handle_request(socket)
        rescue IOError, Errno::EBADF
          break unless @running
          raise
        end
      end
    ensure
      @listener&.close unless @listener&.closed?
      @configuration.delete_state(expected_pid: Process.pid)
    end

    private

    def stop
      @running = false
      @listener.close unless @listener.closed?
    end

    def handle_request(socket)
      Timeout.timeout(2) do
        method, target, headers, body = read_request(socket)
        path, query = target.split("?", 2)
        params = URI.decode_www_form(query.to_s).to_h
        case path
        when "/health"
          if method == "GET"
            nonce = headers["x-open-in-editor-nonce"]
            if nonce && !Authentication.valid_nonce?(nonce)
              return respond(socket, 400, { "error" => "Invalid health nonce" })
            end
            respond(socket, 200, { "ok" => true, "pid" => Process.pid, "protocol" => Configuration::PROTOCOL,
              "bind_address" => @configuration.bind_address, "sessions" => @sessions.keys },
              nonce: nonce, path: path)
          else
            respond(socket, 405, { "error" => "Method not allowed" })
          end
        when "/__open-in-editor"
          method == "GET" ? open_in_editor(socket, params) : respond(socket, 405, { "error" => "Method not allowed" })
        when "/sessions", "/release"
          control_request(socket, method, path, headers, body)
        else
          respond(socket, 404, { "error" => "Not found" })
        end
      end
    rescue ArgumentError, JSON::ParserError, EOFError => error
      respond(socket, 400, { "error" => "Bad request: #{error.message}" })
    rescue Timeout::Error, Errno::EPIPE, Errno::ECONNRESET
      nil
    ensure
      socket.close unless socket.closed?
    end

    def read_request(socket)
      line = socket.gets("\n", 8192)
      raise EOFError, "Missing request line" unless line
      method, target, = line.split(" ")
      raise ArgumentError, "Missing request target" unless target

      headers = {}
      header_bytes = 0
      loop do
        line = socket.gets("\n", 8192)
        raise EOFError, "Incomplete headers" unless line
        header_bytes += line.bytesize
        raise ArgumentError, "Headers too large" if header_bytes > 65_536
        break if line == "\r\n"

        name, value = line.split(":", 2)
        raise ArgumentError, "Invalid header" unless value
        headers[name.downcase] = value.strip
      end
      length = Integer(headers.fetch("content-length", "0"))
      raise ArgumentError, "Invalid content length" unless (0..65_536).cover?(length)
      body = length.zero? ? "" : socket.read(length)
      raise EOFError, "Incomplete body" unless body && body.bytesize == length
      [method, target, headers, body]
    end

    def control_request(socket, method, path, headers, body)
      return respond(socket, 405, { "error" => "Method not allowed" }) unless method == "POST"
      nonce = headers["x-open-in-editor-nonce"]
      valid_nonce = Authentication.valid_nonce?(nonce) && !@used_nonces.key?(nonce)
      return respond(socket, 403, { "error" => "Forbidden" }) unless valid_nonce

      valid_signature = Authentication.valid?(headers["x-open-in-editor-signature"], @token,
        "request", nonce, method, path, body)
      return respond(socket, 403, { "error" => "Forbidden" }) unless valid_signature

      @used_nonces[nonce] = true
      payload = JSON.parse(body)
      path == "/sessions" ? register(socket, payload, nonce) : release(socket, payload, nonce)
    end

    def register(socket, payload, nonce)
      session = payload.fetch("session")
      id = session.fetch("id")
      lease = payload.fetch("lease")
      existing = @sessions[id]
      if existing && existing.reject { |key, _| key == "leases" } != session
        return respond(socket, 409, { "error" => "Checkout already registered with different editor configuration" },
          nonce: nonce, path: "/sessions")
      end
      existing ||= @sessions[id] = session.merge("leases" => [])
      added = !existing.fetch("leases").include?(lease)
      existing.fetch("leases") << lease if added
      respond(socket, 200, { "ok" => true, "added" => added }, nonce: nonce, path: "/sessions")
    end

    def release(socket, payload, nonce)
      id = payload.fetch("session_id")
      session = @sessions[id]
      removed = session && session.fetch("leases").delete(payload.fetch("lease"))
      @sessions.delete(id) if session && session.fetch("leases").empty?
      stopping = !!removed && @sessions.empty?
      respond(socket, 200, { "ok" => true, "stopping" => stopping }, nonce: nonce, path: "/release")
      stop if stopping
    end

    def open_in_editor(socket, params)
      file = params["file"]
      return respond(socket, 400, { "error" => "Missing required query parameter: file" }) if file.nil? || file.empty?

      id = params["session"]
      if id.nil?
        return respond(socket, 400, { "error" => "Specify session when multiple checkouts are registered" }) unless @sessions.size == 1
        id = @sessions.keys.first
      end
      session = @sessions[id]
      return respond(socket, 404, { "error" => "Unknown editor session" }) unless session

      translated_target = translate_target(file, session)
      editor_command = session.fetch("editor_command")
      pid = Process.spawn(*Shellwords.split(editor_command), "--goto", translated_target,
        chdir: session.fetch("working_directory"))
      Process.detach(pid)
      respond(socket, 200, { "ok" => true, "requestedFile" => file, "translatedTarget" => translated_target,
        "editorCommand" => editor_command, "session" => id })
    rescue StandardError => error
      respond(socket, 500, { "ok" => false, "error" => "Failed to open editor: #{error.message}",
        "requestedFile" => file, "translatedTarget" => translated_target, "editorCommand" => editor_command })
    end

    def translate_target(target, session)
      # Query parameters have already been decoded; literal percent signs are filenames.
      match = target.match(/\A(.+?):(\d+)(?::(\d+))?\z/)
      path = match ? match[1] : target
      location = match ? ":#{[match[2], match[3]].compact.join(":")}" : ""
      root = session.fetch("container_root")
      if path == root || path.start_with?("#{root}/")
        path = "#{session.fetch("host_root")}#{path.delete_prefix(root)}"
      end
      "#{path}#{location}"
    end

    def respond(socket, status, payload, nonce: nil, path: nil)
      body = JSON.generate(payload)
      signature_header = ""
      if nonce
        signature = Authentication.signature(@token, "response", nonce, status, path, body)
        signature_header = "X-Open-In-Editor-Signature: #{signature}\r\n"
      end
      socket.write("HTTP/1.1 #{status} #{RESPONSE_PHRASES.fetch(status)}\r\n" \
        "Content-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\n" \
        "X-Open-In-Editor-Bridge: #{Configuration::PROTOCOL}\r\n#{signature_header}" \
        "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    rescue Errno::EPIPE, Errno::ECONNRESET
      # A disconnected HTTP client must not take down other checkout sessions.
      nil
    end
  end
end
