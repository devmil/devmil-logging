# Changelog

## 0.1.0

- Add private bounded Flutter diagnostic history, per-root leases and safe error hooks.
- Add expiring detailed capture, Clear, preview and explicit Save/Share controls.
- Add a bounded Rust event buffer and a Dart-installable availability hook using existing app bridge transports.

- Require explicit native callback detach before cancelling a bridge stream, preventing shutdown from waiting on a Rust-owned sink.
- Preserve the native capture deadline during repeated settings synchronization.
- Honor a pending Clear request when retiring the native bridge.
- Echo sanitized below-INFO records to the explicit debug developer console, and accept a debug-only `developerConsole` sink for tests; history retention is unchanged.
