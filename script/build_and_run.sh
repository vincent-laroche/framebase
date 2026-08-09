#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-build}"
APP_NAME="Framebase"
BUNDLE_ID="com.vincentlaroche.framebase"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Framebase.xcodeproj"
DERIVED_DATA_DIR="$ROOT_DIR/DerivedData"
if ! /usr/bin/xcodebuild -version >/dev/null 2>&1; then
  echo "Framebase requires full Xcode 26. The active developer directory is not a full Xcode installation." >&2
  echo "Install Xcode 26, then select it with: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" >&2
  exit 78
fi

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Missing Xcode project: $PROJECT_PATH" >&2
  exit 66
fi

case "$MODE" in
  build|--build|test|--test|verify|--verify|logs|--logs|telemetry|--telemetry)
    ;;
  *)
    echo "usage: $0 [build|test|verify|logs|telemetry]" >&2
    echo "This project entrypoint is intentionally headless: it never kills or launches Framebase." >&2
    exit 2
    ;;
esac

build_app() {
  /usr/bin/xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    build
}

case "$MODE" in
  build|--build)
    build_app
    ;;
  test|--test)
    swift test --package-path "$ROOT_DIR/Packages/FramebaseKit"
    ;;
  verify|--verify)
    build_app
    swift test --package-path "$ROOT_DIR/Packages/FramebaseKit"
    ;;
  logs|--logs)
    /usr/bin/log show --last 10m --style compact --predicate "process == \"$APP_NAME\""
    ;;
  telemetry|--telemetry)
    /usr/bin/log show --last 10m --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
esac
