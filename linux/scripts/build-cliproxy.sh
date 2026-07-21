#!/usr/bin/env bash
# Build the bundled CLIProxyAPI helper for BirdNion Linux (Tauri).
# Output: linux/src-tauri/binaries/cliproxyapi
#
# Env overrides:
#   CLIPROXYAPI_SOURCE  — Go project root (default: $HOME/Desktop/CLIProxyAPI)
#   GOOS / GOARCH       — target platform (default: host)
#   GO                  — go binary (default: go, then /opt/homebrew/bin/go)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/src-tauri/binaries"
OUT="$OUT_DIR/cliproxyapi"
SRC="${CLIPROXYAPI_SOURCE:-$HOME/Desktop/CLIProxyAPI}"

if [[ ! -d "$SRC" ]]; then
  echo "error: CLIProxyAPI source not found at: $SRC" >&2
  echo "  set CLIPROXYAPI_SOURCE to the Go project root (entrypoint: ./cmd/server)" >&2
  exit 1
fi
if [[ ! -f "$SRC/cmd/server/main.go" && ! -d "$SRC/cmd/server" ]]; then
  echo "error: expected ./cmd/server under $SRC" >&2
  exit 1
fi

GO_BIN="${GO:-}"
if [[ -z "$GO_BIN" ]]; then
  if command -v go >/dev/null 2>&1; then
    GO_BIN="$(command -v go)"
  elif [[ -x /opt/homebrew/bin/go ]]; then
    GO_BIN=/opt/homebrew/bin/go
  else
    echo "error: go toolchain not found" >&2
    exit 1
  fi
fi

mkdir -p "$OUT_DIR"

export CGO_ENABLED=0
# Host defaults when unset (CI sets GOOS=linux for Linux packages).
export GOOS="${GOOS:-$("$GO_BIN" env GOOS)}"
export GOARCH="${GOARCH:-$("$GO_BIN" env GOARCH)}"

echo "Building cliproxyapi → $OUT"
echo "  source: $SRC"
echo "  go:     $GO_BIN ($("$GO_BIN" version))"
echo "  target: ${GOOS}/${GOARCH} CGO_ENABLED=0"

(
  cd "$SRC"
  "$GO_BIN" build -trimpath -ldflags "-s -w" -o "$OUT" ./cmd/server
)

chmod +x "$OUT"
ls -la "$OUT"
echo "OK: cliproxyapi ready"
