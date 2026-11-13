#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter=${FLUTTER_BIN:-flutter}
dart_bin="$(dirname "$(command -v "$flutter")")/dart"
"$dart_bin" format --output=none --set-exit-if-changed lib test
"$flutter" analyze --no-fatal-infos
"$flutter" test
cargo fmt --manifest-path rust/Cargo.toml --check
cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path rust/Cargo.toml --locked
