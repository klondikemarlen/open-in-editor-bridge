# Changelog

## 0.2.0 — 2026-10-09

### Added

- Shared host broker with checkout-specific editor sessions and simultaneous-start coordination.
- `OPEN_IN_EDITOR_BRIDGE_BIND_ADDRESS` for explicit Docker-reachable binding; loopback remains the default.
- Stable checkout IDs through `OpenInEditorBridge.session_id`, `--session-id`, and the `with_running` block argument.
- Independent foreground leases and idempotent detached registration for Compose `up -d` / `down`.

### Changed

- Shutdown releases only the calling checkout's detached registration; the last active lease stops the broker.
- Shared private runtime state replaces checkout-local PID/log files. Stop 0.1.x bridges before upgrading.
- Multi-checkout editor links require an explicit `session` query parameter; single-checkout links remain valid.
- Registration/release use nonce-bound HMAC-authenticated requests/responses and verify protocol/PID identity without transmitting the control secret or signaling disk-sourced PIDs.

### Fixed

- Incorrect host-checkout routing and duplicate-port startup failures for concurrent worktrees.
- Premature detached-session cleanup when using the documented persistent lifecycle.
- Path-prefix collisions and double decoding of percent-encoded filenames.
- Relative editor commands now execute in the requesting checkout, not the checkout that first started the broker.
- Failed health probes preserve live shared-broker credentials instead of orphaning active sessions.
- Malformed authentication bytes are rejected without terminating other checkout sessions.
