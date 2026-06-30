#!/usr/bin/env bash
# Build, package, and publish a new BirdNion release.
#
# Usage:
#   Scripts/release.sh 0.3.1                # bump + build + push release + update cask
#   Scripts/release.sh 0.3.1 --skip-build   # bump versions only, assume pre-built
#   Scripts/release.sh 0.3.1 --dry-run      # print what would happen, no side effects
#
# What it does, in order:
#   1. Verify clean working tree (no uncommitted changes)
#   2. Update MARKETING_VERSION + CFBundleShortVersionString in source
#   3. xcodebuild -quiet build the Release .app
#   4. Copy build/Release/BirdNion.app → ~/Desktop/BirdNion.app
#   5. Zip → ~/Desktop/BirdNion-<version>.zip
#   6. gh release create/upload v<version> on hapo-nghialuu/BirdNion
#   7. Update Casks/birdnion.rb (version + sha256), commit + push to same repo
#   8. Update homebrew-tap/Casks/birdnion.rb, commit + push tap
#
# Install after release:
#   brew install --cask hapo-nghialuu/BirdNion/birdnion
#
# Filename uses `BirdNion-<version>.zip` (no `v` prefix) to work around a
# GitHub release-asset upload cache that returns BlobNotFound for
# `v<version>.zip` filenames on the second upload of the same name.
set -euo pipefail

VERSION="${1:-}"
SKIP_BUILD=0
DRY_RUN=0

for arg in "${@:2}"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version> [--skip-build] [--dry-run]" >&2
  echo "  e.g. $0 0.3.1" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSET_REPO="hapo-nghialuu/BirdNion"
TAP_REPO="hapo-nghialuu/homebrew-tap"
ZIP_NAME="BirdNion-${VERSION}.zip"
DESKTOP="$HOME/Desktop"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must be semver (e.g. 0.3.1), got: $VERSION" >&2
  exit 1
fi

DEV_ENV="$REPO_ROOT/Scripts/dev-env.sh"
if [[ -f "$DEV_ENV" ]]; then
  echo "==> Loading local build env"
  # shellcheck disable=SC1090
  source "$DEV_ENV"
fi

if [[ "$SKIP_BUILD" -eq 0 && "$DRY_RUN" -eq 0 && -z "${HAPO_BASE_URL:-}" ]]; then
  echo "HAPO_BASE_URL is required for release builds. Set it in Scripts/dev-env.sh." >&2
  exit 1
fi

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

echo "==> BirdNion release v${VERSION}"

# 1. Working tree must be clean so we don't ship uncommitted changes
if [[ "$SKIP_BUILD" -eq 0 ]] && ! git -C "$REPO_ROOT" diff --quiet HEAD --; then
  echo "Working tree has uncommitted changes. Commit/stash first, or pass --skip-build." >&2
  exit 1
fi

# 2. Bump versions in source
echo "==> Bumping versions to ${VERSION}"
if [[ "$DRY_RUN" -eq 0 ]]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" \
    "$REPO_ROOT/BirdNion/Info.plist"
  python3 - "$REPO_ROOT" "$VERSION" <<'PY'
import re, sys
root, version = sys.argv[1], sys.argv[2]
path = f"{root}/BirdNion.xcodeproj/project.pbxproj"
with open(path) as f:
    content = f.read()
content = re.sub(r'MARKETING_VERSION = \d+\.\d+\.\d+;',
                 f'MARKETING_VERSION = {version};', content)
with open(path, 'w') as f:
    f.write(content)
PY
fi

# 3. Build (Release, ad-hoc)
if [[ "$SKIP_BUILD" -eq 0 ]]; then
  echo "==> xcodebuild"
  run xcodebuild -quiet -project "$REPO_ROOT/BirdNion.xcodeproj" \
      -scheme BirdNion -configuration Release \
      -destination 'platform=macOS' \
      -derivedDataPath "$REPO_ROOT/build/DerivedData" \
      HAPO_BASE_URL="${HAPO_BASE_URL:-}" \
      HAPO_ME_URL="${HAPO_ME_URL:-}" \
      HAPO_AUTH_TEMPLATE="${HAPO_AUTH_TEMPLATE:-Bearer {token}}" \
      build
fi

BUILT_APP="$REPO_ROOT/build/DerivedData/Build/Products/Release/BirdNion.app"
if [[ ! -d "$BUILT_APP" ]]; then
  BUILT_APP=$(find ~/Library/Developer/Xcode/DerivedData \
                 -name "BirdNion.app" -path "*Release*" -type d 2>/dev/null | head -1)
fi
if [[ -z "$BUILT_APP" ]] || [[ ! -d "$BUILT_APP" ]]; then
  echo "Build output not found. Run without --skip-build." >&2
  exit 1
fi

# 4. Copy to ~/Desktop/BirdNion.app (overwrite)
echo "==> Packaging"
run rm -rf "$DESKTOP/BirdNion.app"
run cp -R "$BUILT_APP" "$DESKTOP/BirdNion.app"
if [[ "$DRY_RUN" -eq 0 ]]; then
  ACTUAL_VER=$(plutil -extract CFBundleShortVersionString raw "$DESKTOP/BirdNion.app/Contents/Info.plist")
  if [[ "$ACTUAL_VER" != "$VERSION" ]]; then
    echo "Bundle version mismatch: requested $VERSION, got $ACTUAL_VER" >&2
    exit 1
  fi
fi

# 5. Zip
ZIP_PATH="$DESKTOP/$ZIP_NAME"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  [dry-run] would zip $DESKTOP/BirdNion.app → $ZIP_PATH"
  ZIP_SHA="(dry-run)"
else
  rm -f "$ZIP_PATH"
  (cd "$DESKTOP" && zip -qr "$ZIP_NAME" BirdNion.app)
  ZIP_SHA=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
fi
echo "    zip: $ZIP_PATH"
echo "    sha256: $ZIP_SHA"

# 6. Upload to GitHub release
TAG="v${VERSION}"
echo "==> gh release ${TAG}"
if gh release view "$TAG" --repo "$ASSET_REPO" >/dev/null 2>&1; then
  echo "    release $TAG exists — uploading new asset"
  run gh release upload "$TAG" "$ZIP_PATH" --repo "$ASSET_REPO"
else
  echo "    creating new release $TAG"
  run gh release create "$TAG" "$ZIP_PATH" \
    --repo "$ASSET_REPO" \
    --title "BirdNion ${TAG}" \
    --notes-file <(git -C "$REPO_ROOT" log --no-merges --pretty=format:"- %s" \
        "$(git -C "$REPO_ROOT" describe --tags --abbrev=0 2>/dev/null || echo HEAD)..HEAD" \
        2>/dev/null)
fi

# Verify upload
if [[ "$DRY_RUN" -eq 0 ]]; then
  DOWNLOAD_SHA=$(curl -sL \
    "https://github.com/${ASSET_REPO}/releases/download/${TAG}/${ZIP_NAME}" \
    | shasum -a 256 | awk '{print $1}')
  if [[ "$DOWNLOAD_SHA" != "$ZIP_SHA" ]]; then
    echo "Upload SHA mismatch! local=$ZIP_SHA downloaded=$DOWNLOAD_SHA" >&2
    exit 1
  fi
  echo "    upload verified: SHA matches"
fi

# 7. Update Casks/birdnion.rb in this repo, commit + push
echo "==> Updating Casks/birdnion.rb"
CASK="$REPO_ROOT/Casks/birdnion.rb"
if [[ "$DRY_RUN" -eq 0 ]]; then
  python3 - "$CASK" "$VERSION" "$ZIP_SHA" <<'PY'
import re, sys
path, version, sha = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    content = f.read()
content = re.sub(r'version "\d+\.\d+\.\d+"', f'version "{version}"', content, count=1)
content = re.sub(r'sha256 "[a-f0-9]{64}"', f'sha256 "{sha}"', content, count=1)
with open(path, 'w') as f:
    f.write(content)
PY
  git -C "$REPO_ROOT" add \
    Casks/birdnion.rb \
    BirdNion/Info.plist \
    BirdNion.xcodeproj/project.pbxproj
  git -C "$REPO_ROOT" commit -m "chore: bump version to ${VERSION}"
  git -C "$REPO_ROOT" push origin main
fi

# 8. Also update homebrew-tap so `brew tap hapo-nghialuu/tap` picks up the new version
echo "==> Updating homebrew-tap cask"
TAP_DIR=$(brew --repository "$TAP_REPO" 2>/dev/null || echo "")
if [[ -z "$TAP_DIR" ]] || [[ ! -d "$TAP_DIR" ]]; then
  TAP_DIR="$REPO_ROOT/.homebrew-tap"
  if [[ ! -d "$TAP_DIR" ]]; then
    run git clone "https://github.com/${TAP_REPO}.git" "$TAP_DIR"
  fi
  run git -C "$TAP_DIR" pull --ff-only
fi

CASK_TAP="$TAP_DIR/Casks/birdnion.rb"
if [[ "$DRY_RUN" -eq 0 ]]; then
  python3 - "$CASK_TAP" "$VERSION" "$ZIP_SHA" <<'PY'
import re, sys
path, version, sha = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    content = f.read()
content = re.sub(r'version "\d+\.\d+\.\d+"', f'version "{version}"', content, count=1)
content = re.sub(r'sha256 "[a-f0-9]{64}"', f'sha256 "{sha}"', content, count=1)
with open(path, 'w') as f:
    f.write(content)
PY
  git -C "$TAP_DIR" add Casks/birdnion.rb
  git -C "$TAP_DIR" commit -m "chore: bump birdnion to ${VERSION}"
  git -C "$TAP_DIR" push --force-with-lease origin main
fi

cat <<EOF

==> Done.
  Release:  https://github.com/${ASSET_REPO}/releases/tag/${TAG}
  Install:  brew tap hapo-nghialuu/tap && brew install --cask birdnion
  Upgrade:  brew upgrade birdnion
  Verify:   brew reinstall --cask birdnion && xattr -l /Applications/BirdNion.app
EOF
