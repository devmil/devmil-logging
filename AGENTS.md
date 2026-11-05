# Devmil Logging

This repository owns generic logging mechanics; applications own reviewed
event policy, localization and product workflow.

Keep all queues and retained data bounded. Never add raw exception/payload or
credential capture, automatic uploads, or default disk/system output. Use the
consumer's existing Flutter Rust Bridge boundary; do not introduce another FFI
mechanism.

Run `./scripts/verify.sh`. Preserve consumer version compatibility. Publish a
verified commit before moving consumers from local development paths to Git pins.
Record public API changes in CHANGELOG.md.
