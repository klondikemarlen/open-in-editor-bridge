# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "rbconfig"
require "shellwords"
require "socket"
require "tmpdir"
require "uri"

require "minitest/autorun"

TEST_LIBRARY_DIRECTORY = ENV.fetch("OPEN_IN_EDITOR_BRIDGE_TEST_LIB", File.expand_path("../lib", __dir__)).freeze
$LOAD_PATH.unshift(TEST_LIBRARY_DIRECTORY)
require "open_in_editor_bridge"

class DockerIntegrationTest < Minitest::Test
  PORT = 3333
  WEB_ROOT = "/usr/src/web"
  NODE_IMAGES = {
    "5.4.20" => "node:22-alpine",
    "6.0.0" => "node:22-alpine",
    "8.0.9" => "node:24.15.0-alpine3.23",
  }.freeze
  IMAGE_PREFIX = "open-in-editor-bridge-runtime-qa"

  def setup
    assert_port_is_free
    @temporary_directory = Dir.mktmpdir("oieb-docker-qa-")
    @runtime_directory = File.join(@temporary_directory, "runtime")
    Dir.mkdir(@runtime_directory, 0o700)
    @projects = []
    @compose_environment = ENV.keys.grep(/\ACOMPOSE_/).to_h { |key| [key, nil] }
    @editor_directory = File.join(@temporary_directory, "editors")
    FileUtils.mkdir_p(@editor_directory)
    @editor_recorder = File.join(@temporary_directory, "record-editor")
    write_editor_recorder
  end

  def teardown
    return unless @temporary_directory

    cleanup_errors = []
    @projects.reverse_each do |project|
      stop_project(project)
    rescue StandardError => error
      cleanup_errors << error.message
    end
    raise "Fixture cleanup failed: #{cleanup_errors.join('; ')}" unless cleanup_errors.empty?

    refute_broker_running
    FileUtils.remove_entry(@temporary_directory)
  end

  def test_two_checkouts_route_encoded_locations_to_their_own_editors_on_vite_5
    assert_two_checkout_routing("5.4.20")
  end

  def test_two_checkouts_route_encoded_locations_to_their_own_editors_on_vite_6
    assert_two_checkout_routing("6.0.0")
  end

  def test_two_checkouts_route_encoded_locations_to_their_own_editors_on_vite_8
    assert_two_checkout_routing("8.0.9")
  end

  def test_wait_keeps_the_detached_editor_registration_until_down
    project = create_project("wait", "6.0.0", healthcheck: true)
    compose(project, "up", "--wait", "--remove-orphans")

    assert_broker_session(project)
    assert_container_has_read_only_integration_mounts(project)

    compose(project, "down", "--remove-orphans")
    refute_broker_running
  end

  def test_wait_equals_true_keeps_the_detached_editor_registration_until_down
    project = create_project("wait-equals-true", "6.0.0", healthcheck: true)
    compose(project, "up", "--wait=true", "--remove-orphans")

    assert_broker_session(project)
    compose(project, "down", "--remove-orphans")
    refute_broker_running
  end

  def test_foreground_completion_releases_its_editor_registration
    project = create_project("foreground", "6.0.0", command: ["sh", "-c", "exit 0"])
    compose(project, "up", "--abort-on-container-exit", "--exit-code-from", "web")

    refute_broker_running
  end

  def test_foreground_compose_failure_releases_its_editor_registration
    project = create_project("foreground-failure", "6.0.0", command: ["sh", "-c", "sleep 30"])

    assert_raises(RuntimeError) do
      compose(project, "up", "--abort-on-container-exit", "missing-service")
    end
    refute_broker_running
  end

  def test_ordinary_compose_commands_and_production_build_have_no_editor_mounts
    project = create_project("ordinary", "6.0.0")
    compose(project, "config", "--quiet")
    compose(project, "run", "--rm", "--no-deps", "web", "sh", "-c", "vite build")

    config = JSON.parse(compose_output(project, "config", "--format", "json"))
    refute config.fetch("services").fetch("web").fetch("volumes", []).any? { |mount| mount.fetch("target", "").start_with?("/open-in-editor-bridge/") }
    refute_broker_running
  end

  def test_adapter_preserves_native_compose_configuration_and_profile_selection
    project = create_project("configuration", "6.0.0", profiles: ["active"])
    File.write(File.join(project.fetch(:root), ".env"), "COMPOSE_FILE=selected.json\nCONFIG_VALUE=from-dot-env\nCOMPOSE_PROFILES=active\n")
    write_compose(project, "selected.json", project_name: "oieb-qa-#{Process.pid}-dot-env", interpolation: "${CONFIG_VALUE}")
    native = native_config(project)
    compose(project, "up", "-d")
    container = service_container(project, "web")
    assert_equal "from-dot-env", container.dig("Config", "Env").find { |value| value.start_with?("CONFIG_VALUE=") }&.delete_prefix("CONFIG_VALUE=")
    assert_equal "${LITERAL_VALUE}", container.dig("Config", "Env").find { |value| value.start_with?("LITERAL_VALUE=") }&.delete_prefix("LITERAL_VALUE=")
    expected_mount = native.dig("services", "web", "volumes").find { |mount| mount["target"] == WEB_ROOT }
    assert_equal expected_mount.fetch("source"), container.dig("Mounts").find { |mount| mount["Destination"] == WEB_ROOT }.fetch("Source")
    assert_equal native.fetch("name"), container.dig("Config", "Labels", "com.docker.compose.project")
    refute service_created?(project, "inactive")
  ensure
    stop_project(project) if project
  end

  def test_explicit_env_file_and_global_multifile_project_options_match_native_compose
    project = create_project("options", "6.0.0", profiles: ["selected"])
    expected_project = "oieb-qa-#{Process.pid}-explicit-multifile"
    project[:options] = ["--project-directory", project.fetch(:root), "--env-file", "custom.env", "-p", expected_project, "-f", "base.json", "-f", "overlay.json"]
    File.write(File.join(project.fetch(:root), "custom.env"), "CONFIG_VALUE=from-explicit-env\nCOMPOSE_PROFILES=selected\n")
    write_compose(project, "base.json", interpolation: "${CONFIG_VALUE}", volume: "./web:/usr/src/web")
    write_compose(project, "overlay.json", project_name: expected_project, profile: "selected")
    overlay_path = File.join(project.fetch(:root), "overlay.json")
    overlay = JSON.parse(File.read(overlay_path))
    overlay.fetch("services")["unselected"] = { "image" => project.fetch(:image), "command" => ["sh", "-c", "sleep 60"] }
    File.write(overlay_path, JSON.generate(overlay))
    options = project[:options]
    native = native_config(project, *options)
    compose(project, "up", "-d", "web")

    container = service_container(project, "web")
    assert_equal "from-explicit-env", container.dig("Config", "Env").find { |value| value.start_with?("CONFIG_VALUE=") }&.delete_prefix("CONFIG_VALUE=")
    assert_equal "${LITERAL_VALUE}", container.dig("Config", "Env").find { |value| value.start_with?("LITERAL_VALUE=") }&.delete_prefix("LITERAL_VALUE=")
    expected_mount = native.dig("services", "web", "volumes").find { |mount| mount["target"] == WEB_ROOT }
    assert_equal File.expand_path(expected_mount.fetch("source")), container.dig("Mounts").find { |mount| mount["Destination"] == WEB_ROOT }.fetch("Source")
    assert_equal expected_project, container.dig("Config", "Labels", "com.docker.compose.project")
    refute service_created?(project, "inactive")
    refute service_created?(project, "unselected")
    assert_container_has_read_only_integration_mounts(project)
  ensure
    stop_project(project) if project
  end

  def test_missing_plugin_identity_fails_safely_without_starting_a_broker
    project = create_project("missing-identity", "6.0.0", mount_plugin: true)
    assert_raises(RuntimeError) { compose(project, "run", "--rm", "web") }

    refute_broker_running
  ensure
    stop_project(project) if project
  end

  def test_request_without_checkout_identity_is_rejected_when_checkouts_are_ambiguous
    projects = [create_project("ambiguous-a", "6.0.0"), create_project("ambiguous-b", "6.0.0")]
    projects.each { |project| compose(project, "up", "-d") }
    response = http_get(PORT, "/__open-in-editor?file=%2Fusr%2Fsrc%2Fweb%2Findex.html%3A1%3A1")

    assert_equal 400, response.code.to_i
    projects.each { |project| assert_broker_session(project) }
  ensure
    projects&.each { |project| stop_project(project) }
  end

  private

  def assert_two_checkout_routing(version)
    image = prepare_vite_image(version)
    first = create_project("#{version}-checkout-a", version, image: image)
    second = create_project("#{version}-checkout-b", version, image: image)
    [first, second].each { |project| compose(project, "up", "-d") }

    [first, second].each { |project| assert_container_has_read_only_integration_mounts(project) }
    first_port = published_port(first)
    second_port = published_port(second)
    targets = [
      [first, request_target(first, second)],
      [second, request_target(second, first)],
    ]
    wait_for_vite(first_port)
    wait_for_vite(second_port)
    targets.each do |project, uri|
      response = http_get(project.fetch(:port), uri)
      assert_equal 200, response.code.to_i, response.body
      assert_match(/"ok":true/, response.body)
    end

    targets.each do |project, _uri|
      expected = File.join(project.fetch(:web_root), project.fetch(:file_name)) + ":17:9"
      record = wait_for_editor_record(project.fetch(:record_path), expected)
      assert_equal project.fetch(:root), record.fetch("cwd")
    end
    compose(first, "down", "--remove-orphans")
    assert_broker_session(second)
    response = http_get(second_port, request_target(second, first))
    assert_equal 200, response.code.to_i, "remaining Vite consumer stopped routing after first checkout down"
    compose(second, "down", "--remove-orphans")
    refute_broker_running
  end

  def request_target(project, hostile_project)
    relative_path = project.fetch(:file_name)
    file = "#{WEB_ROOT}/#{relative_path}:17:9"
    hostile_id = Digest::SHA256.hexdigest(File.realpath(hostile_project.fetch(:root)))
    "/__open-in-editor?file=#{URI.encode_www_form_component(file)}&session=#{hostile_id}&%73ession=hostile-selector"
  end

  def create_project(name, version, image: nil, command: nil, healthcheck: false, profiles: nil, mount_plugin: false)
    root = File.join(@temporary_directory, name)
    web_root = File.join(root, "web")
    FileUtils.mkdir_p(web_root)
    file_name = "literal%20 space-ü-#{name}.html"
    File.write(File.join(web_root, file_name), "<!doctype html><title>#{name}</title>\n")
    File.write(File.join(web_root, "index.html"), "<!doctype html><title>#{name}</title>\n")
    record_path = File.join(@editor_directory, "#{name}.jsonl")
    write_compose_file = File.join(root, "compose.yaml")
    service = {
      "image" => image || prepare_vite_image(version),
      "working_dir" => WEB_ROOT,
      "user" => "#{Process.uid}:#{Process.gid}",
      "volumes" => ["./web:#{WEB_ROOT}"],
      "ports" => ["127.0.0.1::5173"],
      "command" => command || ["sh", "-lc", "vite serve --host 0.0.0.0 --port 5173"],
    }
    service["healthcheck"] = { "test" => ["CMD", "node", "-e", "fetch('http://127.0.0.1:5173').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"], "interval" => "1s", "timeout" => "1s", "retries" => 30 } if healthcheck
    service["profiles"] = profiles if profiles
    project_name = "oieb-qa-#{Process.pid}-#{name.gsub(/[^a-z0-9-]/, '-')}"
    compose_document = { "name" => project_name, "services" => { "web" => service } }
    service["volumes"] << "#{File.expand_path(File.join(TEST_LIBRARY_DIRECTORY, "open_in_editor_bridge/vite.mjs"))}:/open-in-editor-bridge/vite.mjs:ro" if mount_plugin
    File.write(write_compose_file, JSON.pretty_generate(compose_document))
    File.write(File.join(web_root, "vite.config.mjs"), vite_config_source)
    @projects << { root: root, web_root: web_root, name: name, version: version, file_name: file_name,
                   record_path: record_path, image: image || image_name(version), port: nil }
    @projects.last
  end

  def write_compose(project, filename, project_name: nil, interpolation: "${CONFIG_VALUE}", volume: "./web:/usr/src/web", profile: nil)
    document = JSON.parse(File.read(File.join(project.fetch(:root), "compose.yaml")))
    web = document.fetch("services").fetch("web")
    web["environment"] ||= {}
    web["environment"]["CONFIG_VALUE"] = interpolation
    web["environment"]["LITERAL_VALUE"] = "$${LITERAL_VALUE}"
    web["volumes"] = [volume]
    web["profiles"] = [profile] if profile
    document["name"] = project_name if project_name
    document["services"]["inactive"] = { "image" => project.fetch(:image), "command" => ["sh", "-c", "sleep 60"], "profiles" => ["inactive"] }
    File.write(File.join(project.fetch(:root), filename), JSON.pretty_generate(document))
  end

  def vite_config_source
    <<~JAVASCRIPT
      export default async ({ command, mode }) => {
        const plugins = [];
        if (command === "serve" && mode === "development") {
          const integrationPath = "/open-in-editor-bridge/vite.mjs";
          const { default: openInEditorBridge } = await import(integrationPath);
          plugins.push(openInEditorBridge());
        }
        return { plugins, server: { host: "0.0.0.0", strictPort: true } };
      };
    JAVASCRIPT
  end

  def prepare_vite_image(version)
    tag = image_name(version)
    return tag if docker_image_exists?(tag)

    context = File.join(@temporary_directory, "image-#{version}")
    FileUtils.mkdir_p(context)
    base = NODE_IMAGES.fetch(version)
    File.write(File.join(context, "Dockerfile"), <<~DOCKERFILE)
      FROM #{base}
      RUN npm install --global vite@#{version} && mkdir -p /usr/src/web && chown -R node:node /usr/src/web
      USER node
      WORKDIR /usr/src/web
    DOCKERFILE
    docker!("build", "--tag", tag, context)
    tag
  end

  def image_name(version)
    "#{IMAGE_PREFIX}:vite-#{version}"
  end

  def docker_image_exists?(tag)
    _stdout, _stderr, status = Open3.capture3("docker", "image", "inspect", tag)
    status.success?
  end

  def compose(project, *arguments)
    options = project[:options] || []
    env = environment_for(project)
    result = OpenInEditorBridge.compose(*arguments, compose_options: options, env: env, project_root: project.fetch(:root))
    project[:stopped] = true if arguments.first == "down"
    project[:stopped] = false if arguments.first == "up"
    result
  end

  def compose_output(project, *arguments)
    stdout, stderr, status = Open3.capture3(environment_for(project), "docker", "compose", *(project[:options] || []), *arguments, chdir: project.fetch(:root))
    raise "docker compose #{arguments.join(' ')} failed: #{stderr}\n#{stdout}" unless status.success?

    stdout
  end

  def native_config(project, *options)
    stdout, stderr, status = Open3.capture3(environment_for(project), "docker", "compose", *options, "config", "--format", "json", chdir: project.fetch(:root))
    raise "native docker compose config failed: #{stderr}\n#{stdout}" unless status.success?

    JSON.parse(stdout)
  end

  def service_container(project, service)
    ids = compose_output(project, "ps", "-q", service).lines.map(&:strip).reject(&:empty?)
    assert_equal 1, ids.length, "expected one running #{service} container; docker compose ps returned #{ids.inspect}"
    stdout, stderr, status = Open3.capture3("docker", "inspect", ids.first)
    raise "docker inspect failed: #{stderr}" unless status.success?

    JSON.parse(stdout).first
  end

  def service_created?(project, service)
    !compose_output(project, "ps", "-a", "-q", service).strip.empty?
  end

  def published_port(project)
    value = compose_output(project, "port", "web", "5173").lines.first.to_s.strip
    port = value.split(":").last.to_i
    assert_operator port, :>, 0, "expected a published Vite port, got #{value.inspect}"
    project[:port] = port
  end

  def assert_container_has_read_only_integration_mounts(project)
    container = service_container(project, "web")
    mounts = container.fetch("Mounts")
    plugin = mounts.find { |mount| mount["Destination"] == "/open-in-editor-bridge/vite.mjs" }
    identity = mounts.find { |mount| mount["Destination"] == "/open-in-editor-bridge/session.json" }
    assert plugin, "Vite plugin bind mount is missing"
    assert identity, "checkout identity bind mount is missing"
    assert_equal false, plugin.fetch("RW"), "Vite plugin mount must be read-only"
    assert_equal false, identity.fetch("RW"), "checkout identity mount must be read-only"
    manifest = JSON.parse(File.read(identity.fetch("Source")))
    assert_equal %w[session target], manifest.keys.sort, "only non-secret routing fields may be mounted"
    runtime_mounts = mounts.select { |mount| mount.fetch("Source").start_with?("#{@runtime_directory}/") || mount.fetch("Source") == @runtime_directory }
    assert_equal ["/open-in-editor-bridge/session.json"], runtime_mounts.map { |mount| mount.fetch("Destination") }
    environment_names = container.dig("Config", "Env").map { |entry| entry.split("=", 2).first }
    forbidden = %w[OPEN_IN_EDITOR_SESSION_ID OPEN_IN_EDITOR_BRIDGE_SESSION_ID OPEN_IN_EDITOR_BRIDGE_CONTROL_TOKEN OPEN_IN_EDITOR_BRIDGE_RUNTIME_DIR]
    assert_equal [], environment_names & forbidden
  end

  def environment_for(project)
    @compose_environment.merge(
      "OPEN_IN_EDITOR_BRIDGE_BIND_ADDRESS" => "0.0.0.0",
      "OPEN_IN_EDITOR_BRIDGE_RUNTIME_DIR" => @runtime_directory,
      "OPEN_IN_EDITOR_BRIDGE_PORT" => PORT.to_s,
      "OPEN_IN_EDITOR_COMMAND" => "#{Shellwords.escape(@editor_recorder)} #{Shellwords.escape(project.fetch(:record_path))}",
      "OPEN_IN_EDITOR_HOST_WEB_ROOT" => project.fetch(:web_root),
      "OPEN_IN_EDITOR_CONTAINER_WEB_ROOT" => WEB_ROOT,
    )
  end

  def assert_broker_session(project)
    path = "/__open-in-editor?file=#{URI.encode_www_form_component("#{WEB_ROOT}/#{project.fetch(:file_name)}:1:1")}&session=#{Digest::SHA256.hexdigest(File.realpath(project.fetch(:root)))}"
    response = http_get(PORT, path)
    assert_equal 200, response.code.to_i, response.body
  end

  def refute_broker_running
    refute broker_running?, "editor listener remains after final lease release"
  end

  def broker_running?
    Socket.tcp("127.0.0.1", PORT, connect_timeout: 1) { true }
  rescue Errno::ECONNREFUSED
    false
  end

  def http_get(port, path)
    Net::HTTP.start("127.0.0.1", port, nil, open_timeout: 2, read_timeout: 5) do |http|
      http.get(path)
    end
  end

  def wait_for_vite(port)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 45
    loop do
      response = http_get(port, "/")
      return if response.code.to_i == 200
      raise "Vite readiness returned HTTP #{response.code}: #{response.body}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.2
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError
      raise "Vite did not become ready on host port #{port}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.2
    end
  end

  def wait_for_editor_record(path, expected_target)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      if File.file?(path)
        records = File.readlines(path).filter_map do |line|
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end
        record = records.find { |entry| entry.fetch("arguments") == ["--goto", expected_target] }
        return record if record
      end
      raise "editor did not record expected target #{expected_target.inspect} in #{path}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.1
    end
  end

  def write_editor_recorder
    File.write(@editor_recorder, <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      File.open(ARGV.fetch(0), "a") do |file|
        file.puts(JSON.generate({ "arguments" => ARGV.drop(1), "cwd" => Dir.pwd }))
        file.flush
      end
    RUBY
    File.chmod(0o755, @editor_recorder)
  end

  def assert_port_is_free
    socket = TCPSocket.new("127.0.0.1", PORT)
    socket.close
    flunk "port #{PORT} is already in use; refusing to start the Docker runtime gate"
  rescue Errno::ECONNREFUSED
    true
  end

  def stop_project(project)
    return if project[:stopped]

    compose(project, "down", "--remove-orphans", "--timeout", "1")
  end

  def docker!(*arguments)
    stdout, stderr, status = Open3.capture3("docker", *arguments)
    raise "docker #{arguments.join(' ')} failed: #{stderr}\n#{stdout}" unless status.success?
  end
end
