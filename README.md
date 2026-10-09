# OpenInEditorBridge

A Ruby gem that runs a shared local HTTP bridge for opening container files in the correct host checkout's editor. Requires Ruby 3.2 or newer; no runtime gem dependencies.

## Install

```ruby
gem "open-in-editor-bridge", "~> 0.2"
```

```sh
gem install open-in-editor-bridge
```

## Foreground Ruby API

Wrap commands whose lifetime matches the application, such as foreground Compose:

```ruby
require "open_in_editor_bridge"

OpenInEditorBridge.with_running do |session_id|
  ENV["OPEN_IN_EDITOR_SESSION_ID"] = session_id
  system("docker", "compose", "up", exception: true)
end
```

The block returns its normal result. Its checkout lease is released in `ensure`, including when the block raises; cleanup does not replace the original exception. Overlapping wrappers have independent leases, even in the same checkout. Finishing one wrapper never releases another wrapper or an existing detached registration.

`OpenInEditorBridge.session_id` returns the stable ID for the configured checkout without starting the bridge. `OpenInEditorBridge.new(env: ..., project_root: ...)` supports explicit configuration for library consumers.

## Detached Compose

`up -d` returns before the application stops. Use persistent registration, **not** `with_running` around detached startup:

```ruby
require "open_in_editor_bridge"

OpenInEditorBridge.call("--ensure-running")
ENV["OPEN_IN_EDITOR_SESSION_ID"] = OpenInEditorBridge.session_id
system("docker", "compose", "up", "-d", exception: true)
```

Release that checkout's persistent registration when taking it down:

```ruby
OpenInEditorBridge.with_running(ensure_running: false) do
  system("docker", "compose", "down", exception: true)
end
```

`ensure_running: false` does not register a new lease and releases only the detached registration after the block. You can alternatively call `OpenInEditorBridge.call("--shutdown")` directly. Repeated `--ensure-running` calls are idempotent for a checkout; one `--shutdown` releases its detached registration. Foreground leases and registrations for other checkouts remain active. The listener exits when the last lease is released.

## CLI

Run lifecycle commands from the host checkout (or set `OPEN_IN_EDITOR_PROJECT_ROOT` explicitly):

```sh
export OPEN_IN_EDITOR_COMMAND='code'
# Explicit opt-in for Docker bridge-network access; read the security section.
export OPEN_IN_EDITOR_BRIDGE_BIND_ADDRESS=0.0.0.0
export OPEN_IN_EDITOR_SESSION_ID="$(open-in-editor-bridge --session-id)"
open-in-editor-bridge --ensure-running
docker compose up -d

# Later, with the same port, bind address, runtime directory, and project root:
docker compose down
open-in-editor-bridge --shutdown
```

`--serve` runs the broker in the foreground and registers the current checkout. It requires a free port. Prefer the managed lifecycle above for sharing: manually interrupting a foreground broker stops all its sessions.

## Docker and Checkout Routing

All worktrees using one listener must agree on port, bind address, and runtime directory. Each checkout registers its own host-root mapping and editor command. Simultaneous startup is serialized by a shared per-port lock, not by checkout-local pidfiles.

On Linux, make the host accessible from Compose and pass the checkout ID into the web service:

```yaml
services:
  web:
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      OPEN_IN_EDITOR_SESSION_ID: "${OPEN_IN_EDITOR_SESSION_ID:?Set the host checkout session ID}"
```

The container's dev-server proxy must forward editor requests to `http://host.docker.internal:3333` and add its `OPEN_IN_EDITOR_SESSION_ID` as the `session` query parameter. For example:

```text
GET /__open-in-editor?session=<checkout-id>&file=%2Fusr%2Fsrc%2Fweb%2Fapp.rb%3A12%3A4
```

`GET /health` reports the broker PID, protocol, bind address, and active checkout IDs. `GET /__open-in-editor` spawns the registered editor with `--goto <translated-target>`, preserving optional `:line:column`. Container paths equal to or below `/usr/src/web` map to that checkout's host `web` directory. Other paths pass through unchanged. Query encoding is decoded exactly once, preserving literal percent sequences in filenames.

With exactly one checkout, existing links without `session` still work. With multiple checkouts, missing `session` returns HTTP 400 rather than guessing a checkout; unknown IDs return HTTP 404. Registering the same checkout with different roots or editor configuration while it is active is rejected; stop its existing leases before changing configuration.

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

```sh
bundle install
bundle exec rake test
gem build open-in-editor-bridge.gemspec
```

Release changes on an issue-linked branch and pull request, including the version and changelog. Self-review and exercise real host/container lifecycle and editor invocation before merging. From synchronized `main`, build and push the gem with the maintainer's RubyGems credentials, then create a matching GitHub tag/release. Install the published version from RubyGems into a clean `GEM_HOME`, confirm `OpenInEditorBridge::VERSION`, and repeat foreground, detached, routing, and Docker-reachability checks. A recorded editor process proves invocation and arguments, not that an editor window rendered.
