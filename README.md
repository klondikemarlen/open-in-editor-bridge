# OpenInEditorBridge

A Ruby gem that runs a shared local HTTP bridge for opening container files in the correct host checkout's editor. Requires Ruby 3.2 or newer; no runtime gem dependencies.

## Install

```ruby
gem "open-in-editor-bridge", "~> 0.3"
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

Keep your application's existing plugins and other Vite settings. The variable-based dynamic import is intentional: production builds and test-mode configuration can load without Docker's development mounts. This path supports Docker-hosted Vite development; native-host Vite and custom development modes need their own explicit opt-in condition. The plugin requires a valid mounted manifest when enabled and fails startup if it is missing or malformed. Vite 6 is exercised by release QA.

### Application Configuration That Remains

- Select the Vite service (`service: "web"` by default); retain its image, command, source mounts, ports, and normal environment.
- Select Compose files/project options when necessary, for example `compose_options: ["-f", "docker-compose.development.yaml", "-p", "my-checkout"]`. Pass subcommand options after `"up"` / `"down"`, not in `compose_options`.
- Select checkout/container/host roots and the editor through the existing bridge configuration below. `project_root:` defaults to the current checkout; `env:` supplies bridge configuration and child-process environment overrides.
- Explicitly select a Docker-reachable bind address. The adapter rejects loopback startup and never changes the default binding itself.

When no explicit `-f` is supplied, the adapter respects `COMPOSE_FILE` / `COMPOSE_PATH_SEPARATOR`, or discovers a standard Compose file and its default override from the project directory upward. `--project-directory` is supported. Compose runs in `project_root:` and inherits normal process input/output. Failures raise; successful commands return `true`.

Only `up` adds editor setup. Foreground `up` owns an independent lease and releases it even on failure. `up -d` / `up --detach` use the existing idempotent detached registration. Failed detached startup releases a newly acquired registration but preserves one that was already active. Successful `down` releases that checkout's detached registration; failed `down` keeps it. Other commands (`config`, `build`, `exec`, `run`, `logs`, and so on) execute ordinary Compose without editor setup or requiring an editor. `stop` does not release detached registration; use `down` or `--shutdown` when done. If a new container needs the editor mounts, create it through `up`.

The generated override mounts just two read-only files at `/open-in-editor-bridge`: the packaged `vite.mjs` and a checkout-specific `session.json` containing identity and target URL. It never mounts broker state, the whole private runtime directory, or lifecycle control credentials. Temporary Compose overrides are removed after each invocation; non-secret manifests remain in the private host runtime directory for existing detached containers.

All checkouts share the standard host port `3333`, bind address, and private runtime directory. Each may use the same container directory `/usr/src/web`: the plugin selects its own host checkout from its mounted identity. It replaces all caller-supplied `session` selectors, including duplicates and encoded selector names, without rewriting other query bytes. Only `/__open-in-editor` is proxied; health and lifecycle endpoints are not. Existing exact editor proxy entries are replaced, and editor routing takes precedence over broader application proxy entries.

### Adopting in ELCC

After installing 0.3.0, ELCC can replace the editor lifecycle/Compose `up` and `down` path in `bin/dev` with `OpenInEditorBridge.compose`, passing its existing development/gateway `-f` options, project name, host user/group variables, and gateway hostname. Keep gateway lifecycle ownership and pipe-input handling for unrelated commands unchanged.

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

## Development and Release

Commit the root `Gemfile.lock` to keep development and release-test dependencies reproducible. Regenerate it with Bundler after changing `Gemfile`, and commit both files together when both change. This development lockfile is not included in the gem package and does not constrain applications installing this gem; those applications resolve the gemspec's dependencies using their own lockfiles.

Keep generated `*.gem` packages, `.ruby-lsp/` editor state, and local `pkg/` / `tmp/` artifacts out of version control.

Development checks require Node.js 18+ for the bundled Vite plugin's dependency-free tests; the Ruby library itself remains dependency-free. `rake test` runs both Ruby and Node checks.

```sh
bundle install
bundle exec rake test
gem build open-in-editor-bridge.gemspec
```

Release changes on an issue-linked branch and pull request, including the version and changelog. Self-review and exercise real host/container lifecycle and editor invocation before merging. From synchronized `main`, build and push the gem with the maintainer's RubyGems credentials, then create a matching GitHub tag/release. Install the published version from RubyGems into a clean `GEM_HOME`, confirm `OpenInEditorBridge::VERSION`, and repeat foreground, detached, routing, and Docker-reachability checks. A recorded editor process proves invocation and arguments, not that an editor window rendered.
