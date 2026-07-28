# OpenInEditorBridge

A small Ruby gem that runs a local HTTP bridge for opening files from a container in the host editor.

## Install

```ruby
gem "open-in-editor-bridge"
```

## Ruby API

Wrap the local development command that needs the bridge:

```ruby
require "open_in_editor_bridge"

OpenInEditorBridge.with_running do
  # Run the command that emits open-in-editor links.
end
```

Use `ensure_running: false` when the wrapped command is responsible for stopping the bridge:

```ruby
OpenInEditorBridge.with_running(ensure_running: false) { run_down_command }
```

The bridge is stopped in the wrapper's `ensure` path. A block exception remains the raised exception.

## CLI

```sh
open-in-editor-bridge --ensure-running
open-in-editor-bridge --shutdown
open-in-editor-bridge --serve
```

The server provides `GET /health` and `GET /__open-in-editor?file=...`. Container paths beginning with `/usr/src/web` are mapped to the host `web` directory, preserving optional `:line:column` locations.

## Configuration

- `OPEN_IN_EDITOR_BRIDGE_PORT` (default `3333`)
- `OPEN_IN_EDITOR_PROJECT_ROOT` (default current directory)
- `OPEN_IN_EDITOR_CONTAINER_WEB_ROOT` (default `/usr/src/web`)
- `OPEN_IN_EDITOR_HOST_WEB_ROOT` (default `<project-root>/web`)
- `OPEN_IN_EDITOR_COMMAND` (or `EDITOR`)

The editor command is required and is parsed with `Shellwords`.
