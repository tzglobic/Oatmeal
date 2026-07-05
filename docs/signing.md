# Code signing & permissions (local dev)

## Why this matters

macOS ties Screen Recording / Microphone grants (TCC) to an app's **code signature
identity**. An **ad-hoc** signature (`codesign --sign -`) has no stable identity —
its cdhash changes on every build — so macOS forgets the grant every time the app is
rebuilt. You'd have to re-grant Screen Recording after each change. That was the cause
of the "permission is already granted but the app says it isn't" problem.

## The fix: sign with a stable identity

`Scripts/build-app.sh` signs with the first available self-signed identity, in order:

1. `Oatmeal Dev`
2. `LocalFlow Dev`  ← currently used (shared with the LocalFlow project)
3. ad-hoc (`-`) — fallback, with a warning; grant will not persist

Because the identity (and thus the TCC designated requirement) is now stable, you grant
Screen Recording **once** and it survives all future rebuilds.

## First-time grant

After a fresh build or a `tccutil reset`:

1. Launch Oatmeal, press **Record**.
2. System Settings → Privacy & Security → **Screen & System Audio Recording** → enable Oatmeal.
3. **Quit and reopen Oatmeal** — macOS only applies a new Screen Recording grant on relaunch.
4. Press Record again. It will keep working across rebuilds from now on.

To start clean: `tccutil reset ScreenCapture com.oatmeal.app`.

## Giving Oatmeal its own identity (optional)

To stop sharing `LocalFlow Dev`, create a dedicated self-signed code-signing
certificate named **Oatmeal Dev** (Keychain Access → Certificate Assistant → Create a
Certificate → Code Signing, self-signed) and install it in the login keychain. The
build script picks it up automatically (it's first in the preference list) and it can
coexist with an existing Screen Recording grant only if you re-grant once, since the
signing identity changes.

## Phase 7

Distribution builds replace all of this with a Developer ID certificate + notarization,
which is both stable and Gatekeeper-trusted on other Macs.
