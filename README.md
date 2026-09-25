# SoftLock

SoftLock is a native macOS menu bar app for leaving long-running local agents active while blocking casual access to the computer.

It does not log out, sleep, or pause background processes. When you choose **Lock Now** from the menu bar icon, it places a lock window on every display and keeps focus on the password prompt until a password or recovery code is entered.

## Build

```bash
swift build -c release
```

To create a double-clickable macOS app bundle:

```bash
chmod +x scripts/package-app.sh
scripts/package-app.sh
```

The app is written to `dist/SoftLock.app`.

## Run

```bash
.build/release/SoftLock
```

Or open `dist/SoftLock.app` after packaging.

On first launch, SoftLock appears in the menu bar and asks you to create a passcode. You can
choose a **password** or an iPhone-style **4- or 6-digit PIN**. It also shows a one-time
recovery code. Save that code in a password manager.

In PIN mode the lock screen shows the numeric keypad; if you forget your PIN, tap **Forgot PIN?**
to enter the recovery code instead. After several wrong attempts SoftLock briefly throttles
further tries (an escalating delay) to slow brute-force guessing of a short PIN.

After setup:

1. Click the lock icon in the macOS menu bar.
2. Choose **Lock Now** (or press the global shortcut, default ⌃⌥⌘L).
3. Enter your password to unlock.

You can change the global lock shortcut in **Settings...** — click the shortcut field and
press your preferred combination. It works system-wide, even when SoftLock isn't focused.

If you forget the password, enter the recovery code on the lock screen. SoftLock unlocks and asks you to create a new password.

Use **Settings...** from the menu bar to customize:

- Lock screen title
- Background effect: transparent, percentage blur, solid color palette, or a custom image/video; the Apple picker separates Photos/Videos and shows macOS desktop pictures, `.madesktop` thumbnails, bundled wallpaper videos, and downloaded Apple aerial videos as previews
- Input appearance: light, dark, or automatic contrast selection. In transparent/blur modes, automatic mode samples each display before the lock overlay appears.
- Liquid glass inputs: optional glass-styled settings and lock-screen inputs; off by default.
- Open at Login
- A global lock shortcut (default ⌃⌥⌘L), recordable in Settings
- Unlock with Touch ID (on Macs with a Touch ID sensor)
- Optional Unlock with Face (off by default; weaker than Touch ID, see below)
- Capture a local camera photo after failed unlock attempts
- Maximum number of failed-attempt photos to keep

The lock screen footer always shows `softlock by oguzberkacar`.

## Touch ID

On a Mac with Touch ID (built-in or Magic Keyboard), SoftLock can unlock with your
fingerprint. Enable **Unlock with Touch ID** in Settings. When the screen locks, the
system Touch ID prompt appears automatically; you can also tap **Unlock with Touch ID**
on the lock screen. Your password always remains available as a fallback.

Touch ID and saved permission grants rely on a stable code signature, so the app bundle
is signed with a fixed identifier (`com.softlock.agent-shield`) by `scripts/package-app.sh`.

## Unlock with Face (optional, off by default)

Settings → Security → **Unlock with Face**. Enroll once with a guided capture (center, both
sides, tilt up and down), then turn it on. On the lock screen SoftLock looks for you with the
camera and unlocks the same way Touch ID does. The passcode, PIN and recovery code always keep
working.

The scan is manual by default: the lock screen shows a camera button, and pressing **Space**
starts a scan too (Space is only taken as the shortcut while the passcode field is empty, so
spaces inside a password still type). This is deliberate — with automatic scanning, locking the
Mac and walking away lets the camera catch you on the way out and unlock right again. Turn on
**Scan automatically when locked** in Settings → Security if you want the old behaviour.

How it works: Vision finds the face and 5 landmarks, the face is aligned to 112x112, and an
on-device ArcFace (`w600k_mbf`) Core ML model turns it into a 512-number signature that is
compared by cosine similarity against your enrolled signatures (strict threshold 0.66; the
average and at least one individual sample must both clear it, over several consecutive
frames). Liveness runs in "heavy" mode: screen glare and device-bezel cues deny, and at least
one proof-of-life cue (blink, head-turn depth) must confirm. After 3 missed scans face unlock
pauses until you unlock another way.

Read this before enabling: **face unlock is weaker than Touch ID or your passcode.** It uses
the regular 2D camera. The liveness checks stop a printed or on-screen photo far better than
nothing, but they cannot rule out a replayed video or a good mask. Use it for convenience only.

Privacy: only the encrypted signatures are stored (AES-GCM; the key lives in the login
Keychain, this device only) in `~/Library/Application Support/com.softlock.agent-shield/face-profile.enc`.
Camera frames are analyzed in memory and never written to disk (the separate failed-attempt
photo feature is unchanged). **Delete Face Data** in Settings removes the file and the key.
The camera permission is requested from Settings, not from the lock screen.

The model is not compiled by `swift build`. `scripts/package-app.sh` compiles
`Models/ArcFace.mlpackage` into `SoftLock.app/Contents/Resources/ArcFace.mlmodelc`. Without it
the option is disabled in Settings with an explanation. `scripts/convert_arcface.py` (with
`scripts/arcface-requirements.txt`) regenerates the package from InsightFace's ONNX weights
and checks parity.

Face recognition and liveness code is adapted from [jonnyoo/glance](https://github.com/jonnyoo/glance)
(MIT); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), which also covers the model
weights' separate terms.

Failed-attempt photos are stored locally at:

```bash
~/Library/Application Support/com.softlock.agent-shield/failed-attempts
```

To reset the local password:

```bash
.build/release/SoftLock --reset-password
```

## Updates

SoftLock updates itself with [Sparkle](https://sparkle-project.org). It checks once a day,
shows what changed, and installs only after you agree — a lock app should not replace itself
behind your back. **Check for Updates...** is in the menu bar menu.

Every update is verified against SoftLock's EdDSA key (`SUPublicEDKey` in the bundle's
Info.plist) before it is unpacked, and each DMG is notarized by Apple.

To cut a release: bump `APP_VERSION` / `APP_BUILD` in `scripts/package-app.sh`, add the
matching section to `CHANGELOG.md` and `Changelog.entries` in `Sources/SoftLock/main.swift`,
then run `scripts/release.sh`. It builds and notarizes the DMG, signs it with the Sparkle key
in your login keychain, writes `appcast.xml` and publishes both as GitHub release assets.

## Required macOS Permission

Open **System Settings -> Privacy & Security -> Accessibility** and allow `SoftLock`.

Without Accessibility permission, the blurred shield windows still appear, but global keyboard and mouse protection is weaker because macOS blocks third-party event interception.

If macOS still asks after you enabled it, remove the old `SoftLock.app` entry from the
Accessibility list, add the newly signed `/Users/oguzberkacar/Documents/softlock/dist/SoftLock.app`
again, then restart SoftLock. After that, keep using the packaged scripts so the app keeps the
same signed identity across rebuilds.

If failed-attempt photo capture is enabled, macOS will also ask for Camera permission.

For local development, avoid ad-hoc signing if you want macOS permissions to survive
rebuilds. `scripts/package-app.sh` picks the best stable identity automatically:
`Developer ID Application` → `Apple Development` → a self-signed `SoftLock Self-Signed`
certificate. All three keep a constant designated requirement, so Accessibility, Screen
Recording, and Camera grants stick across rebuilds. Only ad-hoc signing (no certificate at
all) changes the code identity each build and forces re-granting.

If you have no Apple certificate yet (e.g. your Developer Program membership is still
pending and `security find-identity -v -p codesigning` lists nothing valid), create a
stable self-signed identity once:

```bash
chmod +x scripts/make-signing-cert.sh
scripts/make-signing-cert.sh
```

The first build after that may ask you to "Always Allow" `codesign` to use the key — accept
once and subsequent builds are silent. You can also choose an exact identity:

```bash
security find-identity -v -p codesigning
SOFTLOCK_SIGN_IDENTITY="Apple Development: your@email.com (TEAMID)" scripts/package-app.sh
```

The packaging script also strips the `com.apple.quarantine` flag from the built bundle so a
locally built app doesn't trip Gatekeeper. For public distribution and notarization, use a
`Developer ID Application` certificate instead.

If you ever need a fully clean slate, open SoftLock → **About → Delete SoftLock…**. It
erases your passcode, settings, and stored data, and runs `tccutil reset All` to revoke the
permission grants, then quits — so a reinstall starts fresh without stale permissions to
remove by hand.
Screen Recording is also used when **Input appearance** is `Auto` over transparent or blur
backgrounds, because SoftLock samples the visible screen to choose readable controls.

## DMG Export

Create a shareable DMG:

```bash
chmod +x scripts/package-dmg.sh
scripts/package-dmg.sh
```

The DMG is written to `dist/SoftLock.dmg`.

## Developer ID Signing and Notarization

For public distribution outside the Mac App Store, create a **Developer ID Application**
certificate in your Apple Developer account, install it in Keychain, then confirm the exact
identity string:

```bash
security find-identity -v -p codesigning
```

Store notarization credentials once, using an app-specific password from appleid.apple.com:

```bash
xcrun notarytool store-credentials softlock-notary --apple-id "you@example.com" --team-id "TEAMID"
```

That is the only manual step. From then on the normal command notarizes and staples on its
own, because notarization defaults to `auto` — it runs whenever a Developer ID identity and a
stored notary profile are both present:

```bash
scripts/package-dmg.sh
```

Set `SOFTLOCK_NOTARIZE=1` to *require* notarization and fail the build if it can't run, or
`SOFTLOCK_NOTARIZE=0` to skip it for a quick local DMG. Use `SOFTLOCK_NOTARY_PROFILE` if the
profile is stored under a different name. In `auto` mode a missing profile is only a warning:
the DMG is still signed, it just makes testers right-click and choose Open on first launch.
The script prints whether the result ended up notarized, along with its SHA-256.

`scripts/package-app.sh` refuses to package when the version in its `APP_VERSION` disagrees
with the top entry of `Changelog.entries` in `Sources/SoftLock/main.swift` or of
`CHANGELOG.md`, so a release can't ship with a bundle version that contradicts its own
What's New list.

If no usable signing certificate exists, the packaging scripts fall back to ad-hoc signing for
local development. Ad-hoc signing is convenient, but macOS permissions may need to be granted
again after rebuilds because the code identity changes. Developer ID signing enables hardened
runtime and uses `scripts/SoftLock.entitlements` for camera access.

## Security Model

SoftLock is a convenience lock for shared office situations where your local jobs must continue running. It is not a replacement for FileVault, the macOS login screen, MDM policy, or physical device security. macOS may reserve some system-level key combinations and recovery paths that third-party apps cannot fully override.
