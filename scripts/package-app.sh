#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/SoftLock.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
APP_IDENTIFIER="${SOFTLOCK_APP_IDENTIFIER:-com.softlock.agent-shield}"
ENTITLEMENTS_PATH="${SOFTLOCK_ENTITLEMENTS:-$ROOT_DIR/scripts/SoftLock.entitlements}"

# Bump these when cutting a release, together with the top entry of `Changelog.entries` in
# Sources/SoftLock/main.swift and of CHANGELOG.md. The three are cross-checked below.
APP_VERSION="0.5.3"
APP_BUILD="10"

SIGN_CERT_NAME="${SOFTLOCK_SIGN_CERT_NAME:-SoftLock Self-Signed}"
# Sparkle auto-update. The feed is an asset of the GitHub release, so the URL stays constant
# across versions. SUPublicEDKey is the public half of the EdDSA key in the login keychain
# ("Private key for signing Sparkle updates"); scripts/release.sh signs each DMG with it.
SPARKLE_FEED_URL="${SOFTLOCK_FEED_URL:-https://github.com/oguzberkacar/softlock/releases/latest/download/appcast.xml}"
SPARKLE_PUBLIC_KEY="${SOFTLOCK_SPARKLE_KEY:-witpMDAwsHXfoiYOrewl0A/NQp+LiCol2+gVv/CTpbo=}"
SPARKLE_FRAMEWORK="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

# A real Developer ID enables notarization, so it gets the hardened runtime + secure
# timestamp meant for distribution.
developer_id_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Developer ID Application:/{if (!devid) devid=$2} END{if (devid) print devid}'
}

# Best available identity for keeping macOS permission grants stable across rebuilds:
# Developer ID > Apple Development > our stable self-signed cert. Anything here beats the
# ad-hoc identity, whose hash (and therefore the TCC grants keyed to it) changes on every
# build — which is what forced re-granting permissions after each rebuild.
#
# Every candidate is collected and the winner printed once in END. Selecting with a bare
# `print; exit` does not work here: awk still runs END on exit, so a machine that had both
# a Developer ID and an Apple Development cert emitted two hashes, the `$SIGN_IDENTITY` =
# `$DEVELOPER_ID` comparison below failed, and codesign was handed a two-line identity.
find_sign_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -v self="$SIGN_CERT_NAME" '
        /Developer ID Application:/{if (!devid) devid=$2}
        /Apple Development:/{if (!dev) dev=$2}
        $0 ~ self {if (!selfid) selfid=$2}
        END{ if (devid) print devid; else if (dev) print dev; else if (selfid) print selfid }'
}

DEVELOPER_ID="$(developer_id_identity)"
SIGN_IDENTITY="${SOFTLOCK_SIGN_IDENTITY:-$(find_sign_identity)}"
SIGN_IDENTITY="${SIGN_IDENTITY:-"-"}"

cd "$ROOT_DIR"

# The version lives in three places that have to agree: this script (Info.plist), the
# in-app What's New list, and CHANGELOG.md. Catch drift here rather than shipping a build
# whose About pane disagrees with its bundle version.
swift_changelog_version() {
  awk -F'"' '/version: "/{print $2; exit}' "$ROOT_DIR/Sources/SoftLock/main.swift"
}
markdown_changelog_version() {
  awk '/^## /{print $2; exit}' "$ROOT_DIR/CHANGELOG.md"
}

SWIFT_VERSION="$(swift_changelog_version)"
MARKDOWN_VERSION="$(markdown_changelog_version)"
if [ "$SWIFT_VERSION" != "$APP_VERSION" ] || [ "$MARKDOWN_VERSION" != "$APP_VERSION" ]; then
  cat >&2 <<EOF
Version mismatch — refusing to package a release with inconsistent versions:
  Info.plist (this script):       $APP_VERSION
  Changelog.entries (main.swift): ${SWIFT_VERSION:-<none>}
  CHANGELOG.md:                   ${MARKDOWN_VERSION:-<none>}
EOF
  exit 1
fi

swift build -c release

if pgrep -x SoftLock >/dev/null 2>&1; then
  pkill -x SoftLock
  sleep 0.3
fi

RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/SoftLock" "$MACOS_DIR/SoftLock"

# Sparkle.framework must live in Contents/Frameworks; the executable is linked with an
# @executable_path/../Frameworks rpath (see Package.swift).
if [ -d "$SPARKLE_FRAMEWORK" ]; then
  mkdir -p "$FRAMEWORKS_DIR"
  rm -rf "$FRAMEWORKS_DIR/Sparkle.framework"
  cp -R "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/Sparkle.framework"
else
  echo "Error: Sparkle.framework not found at $SPARKLE_FRAMEWORK. Run 'swift build' first." >&2
  exit 1
fi

# Face-unlock model (optional feature, off by default in the app). Compile the Core ML package
# into the bundle; without it the app still builds and the Settings pane reports the model as
# missing. See scripts/convert_arcface.py for how Models/ArcFace.mlpackage is produced.
if [ -d "$ROOT_DIR/Models/ArcFace.mlpackage" ]; then
  xcrun coremlcompiler compile "$ROOT_DIR/Models/ArcFace.mlpackage" "$RESOURCES_DIR"
else
  echo "Note: Models/ArcFace.mlpackage not found; Unlock with Face will be unavailable." >&2
fi

# App icon (navy background, yellow lock).
if [ -f "$ROOT_DIR/icon/AppIcon.icns" ]; then
  cp "$ROOT_DIR/icon/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>SoftLock</string>
  <key>CFBundleIdentifier</key>
  <string>__APP_IDENTIFIER__</string>
  <key>CFBundleName</key>
  <string>SoftLock</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>__APP_VERSION__</string>
  <key>CFBundleVersion</key>
  <string>__APP_BUILD__</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSCameraUsageDescription</key>
  <string>SoftLock uses the camera only if you enable Unlock with Face (the video is analyzed on this Mac and never saved) or capture a local photo after failed unlock attempts.</string>
  <key>NSFaceIDUsageDescription</key>
  <string>SoftLock uses Touch ID to unlock the lock screen.</string>
  <key>SUFeedURL</key>
  <string>__SPARKLE_FEED_URL__</string>
  <key>SUPublicEDKey</key>
  <string>__SPARKLE_PUBLIC_KEY__</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>86400</integer>
</dict>
</plist>
PLIST
sed -i '' \
  -e "s/__APP_IDENTIFIER__/$APP_IDENTIFIER/g" \
  -e "s/__APP_VERSION__/$APP_VERSION/g" \
  -e "s/__APP_BUILD__/$APP_BUILD/g" \
  -e "s|__SPARKLE_FEED_URL__|$SPARKLE_FEED_URL|g" \
  -e "s|__SPARKLE_PUBLIC_KEY__|$SPARKLE_PUBLIC_KEY|g" \
  "$CONTENTS_DIR/Info.plist"

# Sparkle's nested code (XPC services, Autoupdate, Updater.app) must be signed inside-out
# before the outer bundle — codesign never descends into it, and `--deep` is explicitly
# unsupported by Sparkle because it rewrites the XPC services' entitlements.
sign_nested() {
  local target="$1"
  shift
  if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - --preserve-metadata=entitlements "$@" "$target"
  elif [ -n "$DEVELOPER_ID" ] && [ "$SIGN_IDENTITY" = "$DEVELOPER_ID" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
      --preserve-metadata=entitlements "$@" "$target"
  else
    codesign --force --sign "$SIGN_IDENTITY" --preserve-metadata=entitlements "$@" "$target"
  fi
}

SPARKLE_BUNDLE="$FRAMEWORKS_DIR/Sparkle.framework"
SPARKLE_VERSION_DIR="$SPARKLE_BUNDLE/Versions/B"
for nested in \
  "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" \
  "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc" \
  "$SPARKLE_VERSION_DIR/Autoupdate" \
  "$SPARKLE_VERSION_DIR/Updater.app"; do
  [ -e "$nested" ] && sign_nested "$nested"
done
sign_nested "$SPARKLE_BUNDLE"

# Sign with a stable identifier matching the bundle id. Touch ID (LocalAuthentication)
# and persisted permission grants (Accessibility, Screen Recording, Camera) are keyed to a
# stable code identity, so we always sign the bundle with a stable identifier.
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "Signing SoftLock.app with ad-hoc identity. macOS permissions will need to be re-granted after rebuilds." >&2
  echo "Tip: run scripts/make-signing-cert.sh once to get a stable identity that keeps permissions." >&2
  codesign --force --sign - \
    --identifier "$APP_IDENTIFIER" \
    --entitlements "$ENTITLEMENTS_PATH" \
    "$APP_DIR"
elif [ -n "$DEVELOPER_ID" ] && [ "$SIGN_IDENTITY" = "$DEVELOPER_ID" ]; then
  # Distribution build: hardened runtime + timestamp so the result can be notarized.
  echo "Signing SoftLock.app with Developer ID: $SIGN_IDENTITY" >&2
  codesign --force \
    --sign "$SIGN_IDENTITY" \
    --identifier "$APP_IDENTIFIER" \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS_PATH" \
    "$APP_DIR"
else
  # Local stable identity (self-signed or Apple Development): no hardened runtime or
  # timestamp — those need a Developer ID / notarization — but the stable identity keeps
  # the permission grants from one build to the next.
  echo "Signing SoftLock.app with local identity: $SIGN_IDENTITY" >&2
  codesign --force \
    --sign "$SIGN_IDENTITY" \
    --identifier "$APP_IDENTIFIER" \
    --entitlements "$ENTITLEMENTS_PATH" \
    "$APP_DIR"
fi

# Strip the quarantine flag so locally built/copied bundles don't trip Gatekeeper prompts.
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true

codesign -dv "$APP_DIR" 2>&1 | sed -n '1,6p'
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "$APP_DIR"
