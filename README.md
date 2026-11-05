# Devmil Logging

Private, bounded diagnostic history for Devmil Flutter applications and their
Rust layers. Capture and disclosure are separate: no automatic application log
files, system-console forwarding, telemetry, or uploads.

## Flutter

`DiagnosticHistory.instance.acquire()` returns an idempotent owner lease.
Acquire before fallible bootstrap, release after cleanup, and give each
composition root its own lease. Safe history survives lease retirement for
failure/retry export; engine restart starts with empty history and details off.
`installDiagnosticErrorHooks()` installs a process lease and safe framework and
platform error hooks before application bootstrap.

Producers emit `DiagnosticEvent` with reviewed stable codes and numeric fields.
Use `detailed: true` for verbose events. A product can provide a
`formatReviewedRecord` adapter for an existing reviewed event vocabulary; never
serialize arbitrary legacy strings or external exceptions there. Failure events
without a reviewed adapter retain their severity as `unclassified_failure`.
Secrets and private product content have no supported event-field type.

Default bounds: 1,000 events, 256 KiB total, 2 KiB per event, with oldest-first
eviction. Capture has no async write queue. Detailed capture is off by default,
expires after at most fifteen minutes, and is disabled on final lease retirement.
`clear()` erases the retained history, including detailed events. Explicit debug
console output requires `--dart-define=DEVMIL_DIAGNOSTIC_CONSOLE=true`. That
developer console receives the same sanitized lines, including below-INFO
operation records that history keeps only while detailed capture is active, so
debug-build process checks can observe startup progress. Release builds have no
console; tests may pass `developerConsole` instead.

`DiagnosticControls` provides localized capture controls, bounded snapshot
preview, Clear, Save and platform text Share. Apps supply ARB-backed labels and
their existing design-system button, spacing and preview size. `DiagnosticExporter`
is the platform adapter and can be replaced in tests. Saving asks for a destination
on desktop/web; mobile offers sharing. Text Share is offered on Android, iOS,
macOS and Windows. Linux offers Save. There are no application-owned temporary
export files. Saved/shared copies are outside Clear history. Export contains
app/build and platform metadata, with no stable device identifier.

Capture is deliberately conservative. To diagnose a new mechanism, add useful
numeric timings, counts, stages and operation transitions at the producer instead
of enabling raw payload dumps. Optional sensitive-context capture and persistent
recording are not implemented. This library must not be presented as consent to
collect credentials, document/message/capture contents or arbitrary paths.

## Rust hook

The `rust/` crate supplies `record`, `install_hook`, `drain`, `set_detailed` and
`clear`. It accepts reviewed static codes and numeric fields only. Native memory
is bounded to 256 events, 64 KiB total, 1 KiB per event. Busy admission drops
events instead of waiting for a logging lock. There is no disk or stderr sink.

Install a callback that signals availability over the application's existing
Flutter Rust Bridge transport. The callback sends no payload, and at most one
notification is outstanding until Dart drains the queue. The callback must
return immediately and must not do application work. `NativeDiagnosticBridge`
connects that stream plus drain/configure callbacks to the Flutter history,
coalesces drains and settings changes, and forwards detail/clear controls.
Install it once alongside the process-owned native bridge. Close it before
retiring that transport: its required detach callback must release the native
`StreamSink` before Dart awaits stream cancellation; a replacement runtime can replace the native hook.
No second FFI implementation is needed.

## Install

The Dart package is all a Flutter-only application needs. An application with a
Rust layer that should record native events also depends on the `devmil-logging`
crate from the same commit, and exposes the hook stream and the drain/configure
calls through its own Flutter Rust Bridge API (see "Rust hook" below); the crate
ships no FFI of its own.

```yaml
dependencies:
  devmil_logging:
    git:
      url: https://github.com/devmil/devmil-logging.git
      ref: <commit sha>
```

```toml
[dependencies]
devmil-logging = { git = "https://github.com/devmil/devmil-logging", rev = "<commit sha>" }
```

## Verify

Run `./scripts/verify.sh`. Tests cover memory bounds, private payload exclusion,
expiry, lease ownership, snapshot isolation, preview-gated export, cancellation,
export failure, and native demand/consent handling. Apps still need their own
producer-policy tests, native packaged-library load checks and platform Save/Share
acceptance. Platform SDK output outside app-owned logging needs separate audit.

## License

MIT. See `LICENSE`.
