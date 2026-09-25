# Changelog

All notable changes to SoftLock are documented here. This file mirrors the in-app
**Settings → About → What's New** list, which is driven by `Changelog.entries` in
`Sources/SoftLock/main.swift`. Keep both in sync when cutting a release, and bump
`CFBundleShortVersionString` in `scripts/package-app.sh` to match.

## 0.5.2 — 2026-09-25

- Fixed a crash that quit SoftLock while the lock screen was up. Starting the camera and
  attaching the lock screen's self-view ran at the same time, and AVFoundation aborts the
  process when the capture session is changed mid-start. The camera now finishes starting
  before anything attaches to it. This could hit any face scan; the manual scan button in
  0.5.1 made it easy to reproduce.

## 0.5.1 — 2026-09-25

- Face unlock no longer scans by itself when the lock screen appears. The lock badge becomes a
  camera button: tap it, or press **Space**, to scan. Automatic scanning meant locking the Mac
  and walking away could let the camera catch you on the way out and unlock right again. The old
  behaviour is still available as **Scan automatically when locked** in Settings → Security.
- Lock-screen status messages moved to the bottom of the screen, so a message appearing or
  growing no longer shifts the passcode layout.
- Locking again after a face unlock no longer shows the previous scan's green tick on the badge.

## 0.5.0 — 2026-09-25

- **Automatic updates** (Sparkle). SoftLock checks once a day for a new version and shows
  what changed; nothing installs until you say so. **Check for Updates...** is in the menu bar
  menu. Every update is verified against SoftLock's EdDSA key before it is unpacked, and the
  DMG is notarized by Apple.
- The lock-screen camera self-view now takes the padlock badge's place above your name,
  instead of sitting at the bottom of the screen. The padlock shows until the camera is live.

## 0.4.0 — 2026-09-25

- New optional **Unlock with Face** (off by default). Enroll in Settings → Security with a
  guided capture: a circular camera preview inside a ring that fills as you turn toward each of
  eight directions, with live feedback for every frame (a **Test Recognition** button checks the
  match without locking). On the lock screen SoftLock scans for your face with the on-device
  ArcFace model and a strict similarity threshold, then unlocks the same way Touch ID does —
  the self-view ring turns green and draws a tick before the lock screen goes away. Only
  encrypted 512-number face signatures are stored (AES-GCM, key in the Keychain); camera frames
  are never kept (except the optional failed-attempt photo below). After 10 missed scans face
  unlock pauses until you unlock another way. The passcode, PIN and recovery code always keep
  working. It is weaker than Touch ID or the passcode: it uses the regular 2D camera and cannot
  rule out a video or a good mask.
- **Liveness checks** are selectable in Settings → Security: *Light* (default) rejects a face
  that looks like a photo or a screen and works while you sit perfectly still; *Heavy* also
  demands a blink or a slight head turn during the scan; *Off* skips the check entirely and
  will let a printed photo in. The device-shaped-rectangle check now only fires when the
  rectangle actually contains the face, so a window, a glass partition or a monitor behind you
  no longer denies the real owner as a spoof.
- On the lock screen a small live self-view ring (white scanning, green recognized, red not
  recognized) shows on the primary display, fed by the same camera session as recognition and
  never recorded. When a face is present but not recognized and failed-attempt photos are on,
  that frame is saved as a failed-attempt photo (once per miss, no second capture session).
- In Heavy mode, a matching face that has not blinked or turned yet prompts "Blink or turn
  slightly" instead of counting as a miss. Scans with no judgeable frame are prompts too.
- Lock-screen status messages sit on a fixed-size dark pill with light text, so they read on
  any wallpaper; red / orange / green only colour a small dot.
- The Touch ID and delete keys on the PIN keypad match the digit keys' size and alignment.
- Face recognition adapted from jonnyoo/glance (MIT); see `THIRD_PARTY_NOTICES.md`.

## 0.3.1 — 2026-07-31

- Logging back into macOS releases SoftLock again. `CGSSessionScreenIsLocked` is only
  published *while* the session is locked, so the unlock check compared an absent key
  against `false` and rejected every notification — the trusted-macOS-unlock stand-down
  (and with it the forgot-PIN escape hatch) never fired.
- Connecting or disconnecting a display during the "too many attempts" wait no longer
  clears it. Rebuilding the lock windows produced a fresh, enabled input; the brute-force
  backoff and the hot-key release gate are now re-applied after a rebuild.
- Touch ID respects the failed-attempt wait, instead of offering a path around the backoff
  the keypad enforces.
- Failed-attempt photos no longer freeze the lock screen: `startRunning()`/`stopRunning()`
  moved off the main thread, and overlapping captures are rejected instead of stacking a
  second capture session and leaving the camera running.
- The passcode prompt is always hosted by exactly one lock window. When `NSScreen.main` is
  nil, every window used to be built as secondary, putting up a lock screen with no way to
  enter a passcode.
- Physical number keys append a single digit to the PIN, so a multi-character key event
  can't overshoot the PIN length and stall the completion check.

## 0.3.0 — 2026-06-29

- Lock screen fits small MacBook displays: the clock, badge and keypad scale down on
  shorter screens.
- Touch ID now sits inside the keypad (the empty key next to 0) instead of taking a
  separate row, freeing vertical space.
- Removed the "by oguzberkacar" lock-screen footer (placeholder until branding is final).
- Permissions only flag what your setup actually needs — Screen Recording shows "not
  needed" unless Auto appearance runs over a transparent/blur background — and each missing
  permission now has a Grant button that opens the right System Settings pane.
- Failed-attempt photos moved next to the capture toggle in Security, with thumbnails of
  the latest captures (click to open) and an Open Folder button.

## 0.2.0 — 2026-06-29

- Mac no longer locks itself while SoftLock is active — an idle-sleep guard (IOKit power
  assertion) keeps the system from sleeping the display and dropping to the macOS login
  window.
- Trusted macOS-login escape hatch: closing the lid or using the macOS lock shortcut now
  releases SoftLock when you log back in, so you never enter a password twice or get
  stranded behind a forgotten PIN.
- Re-locks automatically after an unexpected quit while locked, instead of exposing the
  desktop.

## 0.1.0 — 2026-06-26

- Initial release: menu bar lock with password or 4/6-digit PIN, one-time recovery code,
  Touch ID unlock, customizable lock-screen background, a system-wide lock shortcut, and
  optional failed-attempt camera photos.
