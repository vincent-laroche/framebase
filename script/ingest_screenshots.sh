#!/bin/bash
# Daily Screenshots-library intake. Leaves dropped files in place.
# Does not read iCloud Photos, upload media, or call a cloud model.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/Packages/FramebaseKit"
BIN=""

if [[ -x "$PACKAGE/.build/release/framebase" ]]; then
  BIN="$PACKAGE/.build/release/framebase"
elif [[ -x "$PACKAGE/.build/debug/framebase" ]]; then
  BIN="$PACKAGE/.build/debug/framebase"
else
  echo "Build the local CLI first:" >&2
  echo "  swift build -c release --package-path Packages/FramebaseKit --product framebase" >&2
  exit 1
fi

exec "$BIN" ingest-screenshots "$@"
