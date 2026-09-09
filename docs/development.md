# Architecture and development

## Layout

| Path | Responsibility |
| --- | --- |
| `Sources/Oatmeal/OatmealApp.swift`, `AppDelegate.swift` | Window/menu lifecycle, notifications, shutdown and startup recovery. |
| `Sources/Oatmeal/Views/` | SwiftUI meeting list, notes reader/editor, transcript, settings, and speakers. |
| `Services/RecordingController.swift` (under `Sources/Oatmeal/`) | Main-actor idle/starting/recording/stopping state machine. |
| `Services/RecordingDependencies.swift` | Injectable hardware, permission, clock, and streaming boundaries. |
| `Services/AudioCapture.swift`, `AudioPipeline.swift` | Mic/system sources, resampling, channel alignment, meters, local recording. |
| `Services/DeepgramStreamer.swift`, `TranscriptionService.swift` | Live WebSocket and saved-file transcription. |
| `NotesModel.swift`, `Services/AIService.swift` | Shared editor state, save/retry behavior, provider requests. |
| `Store.swift`, `Models.swift` | GRDB/SQLite records, migrations, search, pending enhancement jobs. |
| `MeetingTimeline.swift`, `NotesDocument.swift`, `NoteCheckbox.swift` | Pure presentation helpers. |
| `Tests/`, `Scripts/`, `Support/` | Regression checks, build tools, bundle metadata and entitlements. |

Paths without a prefix are relative to `Sources/Oatmeal/` except the final row.

## Recording and persistence

Mic audio comes from AVAudioEngine; system audio comes from ScreenCaptureKit.
The pipeline converts both to aligned 16 kHz PCM channels, supplies silence for a
missing or paused source, writes a stereo `.m4a`, and feeds a single multichannel
Deepgram connection. The streamer serializes sends, bounds queued audio, and rejects
callbacks from stale connection generations. Transcript offsets use audio frames.

Final transcript segments are persisted as received. Stop shuts down capture,
drains the pipeline, closes the stream with a bounded final-result wait, and updates
only the meeting's end time. Pending enhancement jobs are stored transactionally
and resumed by the application rather than a selected view.

`NotesModel` shares state for each meeting and retains failed saves. Generated
titles and speaker names use conditional updates to preserve manual edits.
SQLite migrations are additive; preserve existing user data when changing schemas.
Search currently uses SQL LIKE across titles, transcript text, and notes.

## Build and tests

```sh
swift build
swift test
bash Scripts/check-presentation.sh
swift build -c release
bash Scripts/build-app.sh release
```

Use Xcode and Swift 6.3 for the full suite. CI configuration is in
[macos.yml](../.github/workflows/macos.yml); it runs presentation checks, XCTest,
and the release build. The package uses Swift 5 language mode via its tools-version
declaration. Do not confuse language mode with the compiler version.

Regression tests use synthetic samples, fake capture/network services and clocks,
temporary recordings, and in-memory databases. They do not need API keys, capture
permissions, or access to a user's meeting store. Presentation checks cover Markdown
blocks, fenced examples, checkbox updates/stale edits, and timeline grouping.

## Manual smoke checks

Use synthetic meeting content and a short recording:

1. Fresh launch; settings, permission prompts, and missing-key errors.
2. Both audio meters respond; transcript arrives; pause/resume stays aligned.
3. Repeated start/stop clicks do not create overlapping sessions.
4. Edit title and scratchpad during capture, change selection, then Stop; edits survive.
5. Verify saved playback, transcript seeking, note generation, and checkbox persistence.
6. Check light/dark appearance, narrow windows, keyboard controls, and speaker editing.
7. Disconnect/reconnect networking; inspect recovery and saved-file re-transcription.
8. Check meeting-end countdown, Keep Recording, and disabling the setting.
9. Quit during capture/generation, reopen, and verify local data and pending jobs.

Real provider calls incur usage. Automated tests do not establish live hardware,
permission, accessibility, or provider compatibility. Document what was actually
validated when opening a pull request.
