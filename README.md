# OpenInEditorBridge

A Ruby gem that runs a shared local HTTP bridge for opening container files in the correct host checkout's editor. Requires Ruby 3.2 or newer; no runtime gem dependencies.

## Install

```ruby
gem "open-in-editor-bridge", "~> 0.4.0"
```

```sh
gem install open-in-editor-bridge
```

## Docker and Vite Integration

Use the host-side Compose adapter and the gem's mounted Vite plugin. The library owns checkout identity transport, the host-gateway entry, and the editor proxy; **do not export a session variable or write a request rewrite**.

Replace the development Compose startup/shutdown call:

```ruby
require "open_in_editor_bridge"

# Explicit network-exposure opt-in; use only on a trusted development network.
ENV["OPEN_IN_EDITOR_BRIDGE_BIND_ADDRESS"] = "0.0.0.0"
ENV["OPEN_IN_EDITOR_COMMAND"] = "code"

OpenInEditorBridge.compose("up", service: "web")
# Detached startup: OpenInEditorBridge.compose("up", "-d", service: "web")
# Shutdown: OpenInEditorBridge.compose("down", service: "web")
```

Add the plugin to your existing Vite configuration for Docker development:

```js
import { defineConfig } from "vite";

export default defineConfig(async ({ command, mode }) => {
  const plugins = [];
  if (command === "serve" && mode === "development") {
    const integrationPath = "/open-in-editor-bridge/vite.mjs";
    const { default: openInEditorBridge } = await import(integrationPath);
    plugins.push(openInEditorBridge());
  }

  return { plugins, server: { host: "0.0.0.0" } };
});
```

Keep your application's existing plugins and other Vite settings. The variable-based dynamic import is intentional: production builds and test-mode configuration can load without Docker's development mounts. This path supports Docker-hosted Vite development; native-host Vite and custom development modes need their own explicit opt-in condition. The plugin requires a valid mounted manifest when enabled and fails startup if it is missing or malformed. The retained Docker gate covers the consumer versions Vite 5.4.20, 6.0.0, and 8.0.9.

### Application Configuration That Remains

- Select the Vite service (`service: "web"` by default); retain its image, command, source mounts, ports, and normal environment.
- Select Compose files/project options when necessary, for example `compose_options: ["-f", "docker-compose.development.yaml", "-p", "my-checkout"]`. Pass subcommand options after `"up"` / `"down"`, not in `compose_options`.
- Select checkout/container/host roots and the editor through the existing bridge configuration below. `project_root:` defaults to the current checkout; `env:` supplies bridge configuration and child-process environment overrides.
- Explicitly select a Docker-reachable bind address. The adapter rejects loopback startup and never changes the default binding itself.

Compose itself resolves the original project configuration before the adapter adds its mounts: default file discovery, `.env` / `--env-file`, `COMPOSE_FILE` / `COMPOSE_PATH_SEPARATOR`, explicit multi-file inputs, project name, source-relative paths, interpolation, and active profiles remain Compose-owned. The adapter reuses Compose's canonical JSON model in a private host-only temporary file, preserving Compose's literal-dollar escaping instead of merging the original sources a second time. `compose_options` retains other global options, and the original subcommand arguments still select services. Compose runs in `project_root:` and inherits normal process input/output. Failures raise; successful commands return `true`.

Only `up` adds editor setup. Foreground `up` owns an independent lease and releases it even on failure. `up -d` / `up --detach` and `up --wait` / `up --wait=true` use the existing idempotent detached registration: readiness-based startup returns while containers remain running, so the editor registration must remain too. Failed detached startup releases a newly acquired registration but preserves one that was already active. Successful `down` releases that checkout's detached registration; failed `down` keeps it. Other commands (`config`, `build`, `exec`, `run`, `logs`, and so on) execute ordinary Compose without editor setup or requiring an editor. `stop` does not release detached registration; use `down` or `--shutdown` when done. If a new container needs the editor mounts, create it through `up`.

The generated override mounts just two read-only files at `/open-in-editor-bridge`: the packaged `vite.mjs` and a checkout-specific `session.json` containing identity and target URL. It never mounts broker state, the whole private runtime directory, or lifecycle control credentials. Temporary Compose overrides are removed after each invocation; non-secret manifests remain in the private host runtime directory for existing detached containers.

All checkouts share the standard host port `3333`, bind address, and private runtime directory. Each may use the same container directory `/usr/src/web`: the plugin selects its own host checkout from its mounted identity. It replaces all caller-supplied `session` selectors, including duplicates and encoded selector names, without rewriting other query bytes. Only `/__open-in-editor` is proxied; health and lifecycle endpoints are not. Existing exact editor proxy entries are replaced, and editor routing takes precedence over broader application proxy entries.

### Adopting in ELCC

After installing 0.4.0, ELCC can replace the editor lifecycle/Compose `up` and `down` path in `bin/dev` with `OpenInEditorBridge.compose`, passing its existing development/gateway `-f` options, project name, host user/group variables, and gateway hostname. Keep gateway lifecycle ownership and pipe-input handling for unrelated commands unchanged.

Remove the `OPEN_IN_EDITOR_SESSION_ID` export from `dynamic_environment_variables`, its web-service pass-through in `docker-compose.development.yaml`, and the handwritten `/__open-in-editor` target/rewrite in `web/vite.config.js`. Add the mounted plugin to the existing Vue/Vuetify/gateway plugin list under the development-only condition above. The adapter supplies the host-gateway entry, so an editor-only `extra_hosts` entry is no longer necessary. Keep the explicit trusted-network bind opt-in and existing root/editor settings. No consumer files are changed automatically.

## Low-Level Ruby API

For non-Compose applications or custom integrations:

```ruby
require "open_in_editor_bridge"

OpenInEditorBridge.with_running do |session_id|
  # A custom integration may use session_id to select this checkout.
  system("./bin/app", exception: true)
end
```

The block returns its normal result. Its checkout lease is released in `ensure`, including when the block raises; cleanup does not replace the original exception. Overlapping wrappers have independent leases, even in the same checkout. Finishing one wrapper never releases another wrapper or an existing detached registration.

`OpenInEditorBridge.session_id` returns the stable ID without starting the bridge. `OpenInEditorBridge.new(env: ..., project_root: ...)` supports explicit configuration. `call("--ensure-running")` registers a detached checkout; `call("--shutdown")` releases it. Repeated registration is idempotent. `with_running(ensure_running: false)` runs its block without acquiring a lease and releases detached registration afterward. Do not wrap detached startup in a foreground lease.

## CLI and Session Protocol

Run lifecycle commands from the host checkout (or set `OPEN_IN_EDITOR_PROJECT_ROOT`):

```sh
open-in-editor-bridge --session-id
open-in-editor-bridge --ensure-running
# Later, with the same configuration:
open-in-editor-bridge --shutdown
```

The CLI is the low-level lifecycle interface, not a substitute for the Docker/Vite adapter. `--serve` runs a foreground broker and registers the current checkout; it requires a free port. Manually interrupting it stops all sessions. Prefer the managed API for sharing.

`GET /health` reports PID, protocol, bind address, and active checkout IDs. `GET /__open-in-editor?file=<encoded-target>&session=<checkout-id>` spawns that checkout's editor with `--goto <translated-target>`, preserving optional `:line:column`. Paths equal to or below `/usr/src/web` map to the host `web` directory; other paths pass through unchanged. Query encoding is decoded exactly once, preserving literal percent sequences in filenames.

Custom integrations may use the same session protocol. With exactly one checkout, links without `session` work. With multiple checkouts, missing identity returns HTTP 400 rather than guessing; unknown IDs return HTTP 404. Conflicting roots/editor settings for an active checkout are rejected. Foreground and detached leases are independent; the last released lease shuts down the listener.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `OPEN_IN_EDITOR_BRIDGE_PORT` | `3333` | Shared host listener port |
| `OPEN_IN_EDITOR_BRIDGE_BIND_ADDRESS` | `127.0.0.1` | Listener address; `0.0.0.0` allows Docker IPv4 access |
| `OPEN_IN_EDITOR_PROJECT_ROOT` | Current directory | Checkout identity and default host mapping |
| `OPEN_IN_EDITOR_CONTAINER_WEB_ROOT` | `/usr/src/web` | Container directory to translate |
| `OPEN_IN_EDITOR_HOST_WEB_ROOT` | `<project-root>/web` | Corresponding host directory |
| `OPEN_IN_EDITOR_COMMAND` | `EDITOR` | Editor command, parsed with `Shellwords` |
| `OPEN_IN_EDITOR_BRIDGE_RUNTIME_DIR` | `<system-tmp>/open-in-editor-bridge-<uid>` | Shared private host runtime state |
| `OPEN_IN_EDITOR_BRIDGE_STARTUP_TIMEOUT` | `5` seconds | Startup/shutdown deadline |

The editor command is required when registering a checkout, but not for `--session-id` or `--shutdown`. Editors run in their registered checkout's project root, so relative commands such as `./bin/editor` resolve in the correct checkout. Runtime directories must be owned by the current user and private (`0700`). Broker state and its control token use `0600`; runtime files are keyed by port. Checkout IDs derive from the canonical absolute project root.

## Security and Upgrade Notes

Loopback binding is the default. `0.0.0.0` also exposes the listener to other reachable network peers, not only Docker. Use it only on a trusted development network with host firewall restrictions; a specific Docker-reachable host interface can narrow exposure. Editor requests are intentionally unauthenticated and health exposes checkout IDs: anyone who can reach the listener can invoke configured editors. Do not expose it on an untrusted network or forward it publicly.

Registration and release use nonce-bound HMAC signatures derived from a random control token held in the private host runtime directory; the token is never sent over HTTP. Clients authenticate health and control responses and verify broker protocol/PID against shared state. The broker rejects replayed control requests. Shutdown uses authenticated HTTP control, never signals a PID read from disk. Unknown listeners, old bridge versions, mismatched PIDs, and mismatched bind configurations are not reused.

A failed or timed-out health probe does not discard a still-listening broker's credentials. Lifecycle operations fail explicitly until its identity can be verified; retry after the listener becomes responsive.

Version 0.2 replaces checkout-local PID/log files with shared runtime state. Stop any 0.1.x bridge using its original installed version before upgrading; it cannot share the new protocol. Sessions live in the broker's memory. After a broker crash or deliberate manual stop, rerun `--ensure-running` for detached applications. Abruptly killed foreground clients cannot execute `ensure`; stop that broker manually and re-register surviving checkouts if their leases become orphaned.

## Public Contract and Versioning

Supported entrypoints are the documented Ruby class methods `compose`, `with_running`, `call`, `session_id`, and `new(env:, project_root:)`; instance `call` / `session_id`; the CLI lifecycle commands; and the health/editor HTTP endpoints. Their documented routing, cleanup, configuration, and error semantics are the consumer contract. `StartupError` identifies broker startup/control failures; Compose process failures raise rather than return a false success.

`Configuration`, `Client`, `Server`, `Docker`, raw lease methods, control-request signing, runtime file layout, generated Compose inputs, and proxy implementation details are internal, even where Ruby permits direct access. Do not build a consumer on those details or put control credentials in containers. HTTP error text, status-log wording, checkout-ID derivation details, and temporary filenames are not compatibility interfaces.

This project follows [Semantic Versioning](https://semver.org/). **0.4.0 remains a development release, not a claim that the integration is frozen.** Use `~> 0.4.0` to stay within the tested minor release line; `~> 0.4` would permit future 0.x minor changes.

**1.0 is a public-API compatibility commitment, not a feature-count milestone.** The Ruby lifecycle is already used by consumers, but the Compose/Vite path is recent and this cycle found configuration-selection and readiness-lifetime defects. Promotion should follow an explicit freeze of the supported API, platform/tool prerequisites, and upgrade policy after real consumer adoption confirms the integration shape and the retained installed-artifact gate passes. No additional feature backlog or arbitrary sequence through 0.5–0.9 is required; the next stable-contract release can go directly to 1.0.

Verified release environments are Linux with Docker Compose supporting `config --format json` and `config --environment` (5.6.0 exercised here), Node 22 with Vite 5.4.20 / 6.0.0, and Node 24 with Vite 8.0.9. Other platforms/tool versions are not implied by this evidence. These capabilities are needed only for the Docker adapter; unrelated Compose commands do not resolve editor configuration.

## Development and Release

Commit the root `Gemfile.lock` to keep development and release-test dependencies reproducible. Regenerate it with Bundler after changing `Gemfile`, and commit both files together when both change. This development lockfile is not included in the gem package and does not constrain applications installing this gem; those applications resolve the gemspec's dependencies using their own lockfiles.

Keep generated `*.gem` packages, `.ruby-lsp/` editor state, and local `pkg/` / `tmp/` artifacts out of version control.

Development checks require Node.js 18+ for the bundled Vite plugin's dependency-free tests; the Ruby library itself remains dependency-free. `rake test` runs both Ruby and Node checks.

```sh
bundle install
bundle exec rake test
gem build open-in-editor-bridge.gemspec
```

Release changes on an issue-linked branch and pull request, including the version and changelog. Self-review and run the normal test gate plus the real Docker gate below before merging. From synchronized `main`, build and push the gem with the maintainer's RubyGems credentials, then create a matching GitHub tag/release. Install the published version from RubyGems into a clean `GEM_HOME`, confirm `OpenInEditorBridge::VERSION`, and run the same Docker gate against its installed library. A recorded editor process proves invocation and arguments, not that an editor window rendered.

### Retained Docker and Vite Gate

```sh
bundle exec rake test:docker
```

The opt-in gate creates isolated temporary Compose projects and requires host port 3333 to be free. It exercises two checkout mappings for each pinned Vite version, encoded paths/locations and hostile selectors, credential isolation, native configuration parity, readiness-based detached lifetime, foreground/error cleanup, ordinary commands, and production builds without editor mounts. It does not run as part of the fast `rake test` gate. Docker and npm registry access are required to prepare the Node/Vite fixture images; projects, leases, networks, and temporary directories are cleaned on exit. Images may be reused between QA runs.

To repeat it against the released gem while retaining the checkout's test tooling:

```sh
release_home="$(mktemp -d)"
GEM_HOME="$release_home" GEM_PATH="$release_home" \
  gem install open-in-editor-bridge --version 0.4.0 \
    --clear-sources --source https://rubygems.org --no-document
GEM_HOME="$release_home" GEM_PATH="$release_home" \
  ruby -ropen_in_editor_bridge -e 'puts OpenInEditorBridge::VERSION'
OPEN_IN_EDITOR_BRIDGE_TEST_LIB="$release_home/gems/open-in-editor-bridge-0.4.0/lib" \
  bundle exec rake test:docker
rm -rf "$release_home"
```
