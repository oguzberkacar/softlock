#!/usr/bin/env bash
set -euo pipefail

# Cuts a release: builds and notarizes the DMG, signs it with the Sparkle EdDSA key,
# writes an appcast.xml, and publishes both as assets of a GitHub release. The feed URL
# baked into the app points at .../releases/latest/download/appcast.xml, so the appcast
# must be attached to every release, not just the first one.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${SOFTLOCK_REPO:-oguzberkacar/softlock}"
STAGING="$ROOT_DIR/dist/appcast"
SPARKLE_BIN="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"

VERSION="$(awk -F'"' '/^APP_VERSION=/{print $2}' "$ROOT_DIR/scripts/package-app.sh")"
BUILD="$(awk -F'"' '/^APP_BUILD=/{print $2}' "$ROOT_DIR/scripts/package-app.sh")"
TAG="v$VERSION"
DMG_NAME="SoftLock-$VERSION.dmg"

if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
  echo "Sparkle tools missing. Run 'swift build' first." >&2
  exit 1
fi

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG already exists on $REPO. Bump APP_VERSION in scripts/package-app.sh." >&2
  exit 1
fi

"$ROOT_DIR/scripts/package-dmg.sh"

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp "$ROOT_DIR/dist/SoftLock.dmg" "$STAGING/$DMG_NAME"

# Release notes shown inside Sparkle's update window: the current section of CHANGELOG.md
# as minimal HTML, named so generate_appcast picks it up for this version.
awk -v ver="$VERSION" '
  $0 ~ "^## " ver " " {inside=1; next}
  /^## / {inside=0}
  inside {print}
' "$ROOT_DIR/CHANGELOG.md" \
  | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
  | awk '
      BEGIN {print "<html><body style=\"font: -apple-system-body; padding: 0 8px;\"><ul>"; open=0}
      /^- / {if (open) print "</li>"; printf "<li>%s", substr($0, 3); open=1; next}
      /^[[:space:]]+[^[:space:]]/ {if (open) printf " %s", $0; next}
      END {if (open) print "</li>"; print "</ul></body></html>"}
    ' > "$STAGING/SoftLock-$VERSION.html"

# Only the current DMG is staged, so every enclosure URL belongs to this tag's assets.
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO" \
  "$STAGING"

echo "Publishing $TAG to $REPO"
gh release create "$TAG" \
  --repo "$REPO" \
  --title "SoftLock $VERSION" \
  --notes-file <(awk -v ver="$VERSION" '
      $0 ~ "^## " ver " " {inside=1; next}
      /^## / {inside=0}
      inside {print}
    ' "$ROOT_DIR/CHANGELOG.md") \
  "$STAGING/$DMG_NAME" \
  "$STAGING/appcast.xml" \
  "$STAGING/SoftLock-$VERSION.html"

echo "Released $TAG (build $BUILD): https://github.com/$REPO/releases/tag/$TAG"
