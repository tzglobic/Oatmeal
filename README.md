# Oatmeal

A Granola-style AI meeting notepad for macOS. Captures meeting audio without a bot,
lets you type rough notes live, and uses Deepgram + Claude to produce polished notes,
chat, briefs, and recipes. Full roadmap: [granola-clone-plan.md](granola-clone-plan.md).

## Status

**Phase 0 (scaffold) — done.** App builds, API keys persist in the macOS Keychain and
validate against Deepgram/Anthropic, and the (empty) meeting list renders.
Next: Phase 1 — recording + live transcript ([research notes](docs/phase1-audio-research.md)).

## Building

No Xcode required — the Command Line Tools are enough (SwiftPM + a bundling script):

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
