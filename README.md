# Oatmeal

A Granola-style AI meeting notepad for macOS. Captures meeting audio without a bot,
lets you type rough notes live, and uses Deepgram + Claude to produce polished notes,
chat, briefs, and recipes. Full roadmap: [granola-clone-plan.md](granola-clone-plan.md).

## Status

**Phase 2.5 (quality-of-life batch) — done.**
Live mic/system **level meters** and an elapsed timer in the toolbar while recording,
plus **pause/resume** (pause mutes both channels while the clock keeps running, so
timestamps stay aligned). **AI auto-titles** replace "Meeting Jul 6…" after enhancement
(never overwriting a manual title). **Re-transcribe from audio** rebuilds a meeting's
transcript from its `.m4a` via Deepgram's cheaper batch API. The transcript is now a
player: **click any line to hear it**, with a play bar and live highlight. **Search**
covers titles, transcripts, and notes from the sidebar. An **Action Items** view rolls
up unchecked `- [ ]` items across all meetings with click-to-toggle. **Diarization**
splits multiple remote speakers (Them 1 / Them 2) with right-click **speaker rename**.
Meetings can be **renamed** inline (detail header) or via the sidebar context menu.
Settings gains a **health panel** (permissions + keys at a glance), and a **menu-bar
item** starts/stops/pauses recording without the main window.

**Phase 2 (notes editor + AI enhancement) — done.** Each meeting has three tabs:
**Notes** (AI-enhanced, editable), **Transcript**, and **My Notes** (raw notes you type
during the meeting, auto-saved). When a recording stops, Claude merges your raw notes
with the transcript into polished Markdown notes — summary, key points, decisions,
action items — preserving your own bullets Granola-style. A template picker (Standard,
1:1, Sales Call, Standup) switches the enhancement style; Re-enhance regenerates
anytime; Copy puts any tab on the clipboard; meetings can be deleted from the sidebar.
The mic is optional — on a Mac with no input device Oatmeal records system audio only.

**Phase 1 (recording + live transcript) — done.** The Record button captures mic
(AVAudioEngine) and system audio (ScreenCaptureKit, audio-only) simultaneously, streams
both as one two-channel Deepgram connection (nova-3, multichannel), and renders a live
Me/Them transcript with interim results. Final segments persist to SQLite as they arrive
and survive restart; each meeting also gets a stereo `.m4a` fallback recording
(mic = left, system = right). The Deepgram socket sends keepalives and reconnects with
backoff, buffering up to 60s of audio while offline.
Design notes: [docs/phase1-audio-research.md](docs/phase1-audio-research.md).
Next: Phase 3 — calendar integration.

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
