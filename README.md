# Oatmeal

A Granola-style AI meeting notepad for macOS. Captures meeting audio without a bot,
lets you type rough notes live, and uses Deepgram + Claude to produce polished notes,
chat, briefs, and recipes. Full roadmap: [granola-clone-plan.md](granola-clone-plan.md).

## Status

**Phase 1 (recording + live transcript) — done.** The Record button captures mic
(AVAudioEngine) and system audio (ScreenCaptureKit, audio-only) simultaneously, streams
both as one two-channel Deepgram connection (nova-3, multichannel), and renders a live
Me/Them transcript with interim results. Final segments persist to SQLite as they arrive
and survive restart; each meeting also gets a stereo `.m4a` fallback recording
(mic = left, system = right). The Deepgram socket sends keepalives and reconnects with
backoff, buffering up to 60s of audio while offline.
Design notes: [docs/phase1-audio-research.md](docs/phase1-audio-research.md).
Next: Phase 2 — notes editor + AI enhancement.

## Building

> **Requires a Swift 6.3+ toolchain.** The Command Line Tools' Swift 6.2.x compiler
> miscompiles main-actor executor hops, which crashes SwiftUI button taps on
> macOS 26 (see [docs/crash-macos26-executor.md](docs/crash-macos26-executor.md)).
> A `swift-6.3.2-RELEASE` toolchain is installed under
> `~/Library/Developer/Toolchains/`; `build-app.sh` finds it automatically. To get
> one elsewhere: download from https://swift.org/download/ (no Xcode needed).

No Xcode required — the Command Line Tools plus a 6.3+ toolchain are enough:

```sh
Scripts/build-app.sh            # debug build → .build/Oatmeal.app
Scripts/build-app.sh release    # release build
open .build/Oatmeal.app
```

The bundle is ad-hoc signed for personal use. Phase 7 adds Developer ID signing,
notarization, and a distributable DMG. If Xcode is installed later, `open Package.swift`
gives the full IDE experience — the SwiftPM layout works in both worlds.

## First run

1. Launch the app and open **Settings (⌘,)**.
2. Paste your Deepgram and Anthropic API keys and hit **Save & Validate** —
   keys are stored in the Keychain, validation calls are free.

## Layout

- `Sources/Oatmeal/` — app code (SwiftUI views, GRDB store, services)
- `Support/` — Info.plist (permission strings) + entitlements
- `Scripts/build-app.sh` — SwiftPM build → .app bundle → codesign
- `docs/` — phase research notes
