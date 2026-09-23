#!/usr/bin/env bash
# Bump every release version authority to <semver>, no commit.
#
# Usage:
#   Scripts/bump-version.sh 0.10.42
#
# The `release` branch workflow derives the tag from source, so all five files
# must agree before pushing to `release`:
#   BirdNion/Info.plist                  CFBundleShortVersionString
#   BirdNion.xcodeproj/project.pbxproj   MARKETING_VERSION (all occurrences)
#   linux/src-tauri/tauri.conf.json     "version"
#   linux/src-tauri/Cargo.toml          [package] version
#   linux/src-tauri/Cargo.lock          birdnion package entry
set -euo pipefail

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: $0 <semver>   e.g. $0 0.10.42" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

plutil -replace CFBundleShortVersionString -string "$VERSION" \
  "$REPO_ROOT/BirdNion/Info.plist"

python3 - "$REPO_ROOT" "$VERSION" <<'PY'
import re, sys

root, version = sys.argv[1], sys.argv[2]

def sub(path, pattern, repl, count=0):
    with open(path) as f:
        content = f.read()
    with open(path, 'w') as f:
        f.write(re.sub(pattern, repl, content, count=count))

sub(f"{root}/BirdNion.xcodeproj/project.pbxproj",
    r'MARKETING_VERSION = \d+\.\d+\.\d+;',
    f'MARKETING_VERSION = {version};')

sub(f"{root}/linux/src-tauri/tauri.conf.json",
    r'"version": "\d+\.\d+\.\d+"',
    f'"version": "{version}"', count=1)

sub(f"{root}/linux/src-tauri/Cargo.toml",
    r'(?m)^version = "\d+\.\d+\.\d+"',
    f'version = "{version}"', count=1)

sub(f"{root}/linux/src-tauri/Cargo.lock",
    r'(?m)(name = "birdnion"\nversion = ")\d+\.\d+\.\d+(")',
    rf'\g<1>{version}\g<2>', count=1)
PY

echo "==> Bumped all version authorities to ${VERSION}"
git -C "$REPO_ROOT" diff --stat
