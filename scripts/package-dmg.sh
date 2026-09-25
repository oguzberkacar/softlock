#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/SoftLock.app"
DMG_PATH="$ROOT_DIR/dist/SoftLock.dmg"
STAGING_DIR="$ROOT_DIR/dist/dmg-staging"
# auto (default): notarize whenever it can actually work — a Developer ID identity plus a
# stored notarytool profile. Storing the profile is a one-time step, so after that every
# release build comes out notarized and stapled without extra flags.
#   1 = require notarization, fail if the prerequisites are missing
#   0 = skip entirely (quick local DMG)
NOTARIZE="${SOFTLOCK_NOTARIZE:-auto}"
NOTARY_PROFILE="${SOFTLOCK_NOTARY_PROFILE:-softlock-notary}"

# Prefer a Developer ID (the only identity a notarized DMG can carry), else fall back to an
# Apple Development cert. Collect and print once in END — `print; exit` still runs END, so a
# machine with both certs emitted two hashes and codesign rejected the two-line identity.
find_sign_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk '
        /Developer ID Application:/{if (!devid) devid=$2}
        /Apple Development:/{if (!fallback) fallback=$2}
        END{ if (devid) print devid; else if (fallback) print fallback }'
}

developer_id_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Developer ID Application:/{if (!devid) devid=$2} END{if (devid) print devid}'
}

SIGN_IDENTITY="${SOFTLOCK_DMG_SIGN_IDENTITY:-${SOFTLOCK_SIGN_IDENTITY:-$(find_sign_identity)}}"
SIGN_IDENTITY="${SIGN_IDENTITY:-"-"}"
DEVELOPER_ID="$(developer_id_identity)"

# Apple only notarizes Developer ID signatures; an Apple Development cert is rejected.
can_notarize() {
  [ -n "$DEVELOPER_ID" ] && [ "$SIGN_IDENTITY" = "$DEVELOPER_ID" ]
}

notary_setup_hint() {
  cat >&2 <<HINT
To notarize, store the credentials once (needs an app-specific password from
appleid.apple.com), then re-run this script:

  xcrun notarytool store-credentials $NOTARY_PROFILE \\
    --apple-id "<your-apple-id>" --team-id "<your-team-id>"
HINT
}

cd "$ROOT_DIR"
scripts/package-app.sh

rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/SoftLock.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "SoftLock" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$STAGING_DIR"

if [ "$SIGN_IDENTITY" != "-" ]; then
  codesign --force \
    --sign "$SIGN_IDENTITY" \
    --timestamp \
    "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi

notarized=0

if [ "$NOTARIZE" = "0" ]; then
  echo "Notarization skipped (SOFTLOCK_NOTARIZE=0)." >&2
elif ! can_notarize; then
  # No Developer ID means notarization is impossible, not merely unconfigured.
  echo "Notarization unavailable: the DMG is not signed with a Developer ID identity." >&2
  if [ "$NOTARIZE" = "1" ]; then
    exit 1
  fi
else
  echo "Submitting to Apple notary service (this can take a few minutes)..." >&2
  set +e
  notary_output="$(xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
  notary_status=$?
  set -e
  printf '%s\n' "$notary_output" >&2

  if [ "$notary_status" -eq 0 ]; then
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    notarized=1
  elif [ "$NOTARIZE" != "1" ] && printf '%s' "$notary_output" | grep -q "No Keychain password item found"; then
    # One-time setup missing. In auto mode that is not a build failure: the signed DMG is
    # still usable, it just makes testers click through Gatekeeper on first launch.
    echo "Notary profile '$NOTARY_PROFILE' is not stored yet — leaving the DMG signed but not notarized." >&2
    notary_setup_hint
  else
    echo "Notarization failed." >&2
    exit 1
  fi
fi

if [ "$notarized" = "1" ]; then
  spctl -a -vvv -t install "$DMG_PATH" 2>&1 | sed 's/^/  /' >&2
  echo "Notarized and stapled — testers can open it without a Gatekeeper warning." >&2
else
  echo "NOT notarized — testers must right-click the app and choose Open on first launch." >&2
fi

shasum -a 256 "$DMG_PATH" >&2
echo "$DMG_PATH"
