# Plan: "Oatmeal" — a Granola-style AI meeting notepad for macOS

A native Swift/SwiftUI app that captures meeting audio without a bot, lets you type rough notes live, and uses cloud AI to produce polished notes, chat, briefs, and recipes. This plan is written to be handed to Claude Code phase by phase.

## Architecture overview

- **App**: SwiftUI, macOS 14+, single-window app with sidebar (meeting list) + detail (notes editor / transcript / chat).
- **Audio capture**: system audio via ScreenCaptureKit (`SCStream` audio output, no video), mic via `AVAudioEngine`. Two channels tagged "them" / "me" for cheap speaker attribution.
- **Live transcription**: Deepgram streaming WebSocket API (nova-3 model, diarization on). Two parallel streams (mic + system) merged by timestamp.
- **AI**: Claude API (claude-sonnet) for note enhancement, chat, briefs, recipes.
- **Storage**: local SQLite via GRDB. Tables: meetings, transcript_segments, notes (user + enhanced), chats, recipes. No server; everything on-device except API calls.
- **Secrets**: API keys (Deepgram, Anthropic) in macOS Keychain, entered in Settings.
- **Permissions needed**: Microphone, Screen Recording (required for system audio), Calendars (EventKit).

## Phase 0 — Scaffold (½ day)

- Xcode project, SwiftPM deps: GRDB, KeychainAccess.
- App structure: `AudioService`, `TranscriptionService`, `AIService`, `Store` (GRDB), SwiftUI views.
- Settings window for API keys; validate with a test call.
- Entitlements + Info.plist usage strings for mic/screen/calendar.

**Done when**: app builds, keys persist in Keychain, empty meeting list renders.

## Phase 1 — Recording + live transcript (2–3 days)

- Start/stop recording button. On start: request permissions, open SCStream (audio-only) + AVAudioEngine mic tap.
- Convert both to 16kHz linear PCM, stream to two Deepgram WebSocket connections.
- Merge interim/final results into a live transcript view (speaker = Me/Them, timestamps).
- Persist final segments to SQLite as they arrive; handle reconnects and network drops gracefully (buffer audio, resume).
- Also write raw audio to an .m4a file per meeting as a fallback for re-transcription.

**Done when**: you can talk over a Zoom call and watch an accurate two-sided live transcript; segments survive app restart.

## Phase 2 — Notes editor + AI enhancement (2 days)

- Markdown-ish notes editor (TextEditor or a lightweight down-styled editor) usable during recording.
- On stop: send user notes + full transcript to Claude with an enhancement prompt → structured notes (summary, key points, decisions, action items), preserving/expanding the user's own bullets Granola-style.
- Show enhanced notes as the primary view with tabs: Notes / Transcript / My notes (original). Enhanced notes are editable and re-generatable.
- Template picker (default, 1:1, sales call, standup) — just different enhancement prompts.

**Done when**: end a recording and get polished notes that visibly incorporate what you typed.

## Phase 3 — Calendar integration (1 day)

- EventKit: read today's events, show upcoming meetings in sidebar with "Record" affordance.
- Detect video-call URLs (Zoom/Meet/Teams) in event notes/location.
- Auto-title and auto-associate recordings with the current calendar event; store attendees.
- Optional: notification "Meeting starting — start Oatmeal?" when an event with a call link begins.

**Done when**: notes are automatically named/attributed to the right meeting with attendee list.

## Phase 4 — Chat with meetings (2 days)

- Per-meeting chat: transcript + notes as context, streamed Claude responses.
- Cross-meeting chat: retrieval by (a) date/attendee/title filters + (b) simple full-text search (SQLite FTS5) over transcripts to select context. Skip embeddings in v1; FTS is good enough at personal scale.
- Chat history persisted per meeting and one "All meetings" thread.

**Done when**: "what did we decide about pricing last week?" returns a grounded answer citing the meeting.

## Phase 5 — Briefs + Recipes (1–2 days)

- **Briefs**: before an external meeting (attendee domain ≠ yours), generate a brief from prior meetings with those attendees: who they are, last discussion, open action items. Show it on the meeting card.
- **Recipes**: user-defined saved prompts (name, prompt template, output target). Invoke via "/" in chat or a button on a meeting (e.g., /follow-up-email, /crm-summary). CRUD UI in Settings.

**Done when**: opening an upcoming external meeting shows a useful brief; /recipes run on any meeting.

## Phase 6 — Sharing (1 day, lightweight version)

Skip the hosted web-share backend. Instead:

- Export note as Markdown, styled HTML, or PDF.
- "Copy as email" (recipe-powered).
- macOS share sheet integration.

If real Granola-style links are wanted later, add a tiny Cloudflare Workers + KV backend that serves a static note page — separate mini-project.

**Done when**: one click produces a shareable artifact.

## Phase 7 — Packaging + installing on your Macs (½–1 day)

- App icon, About panel, menu bar quick-record item.
- Signing: Developer ID certificate ($99/yr Apple Developer) + notarization → distributable DMG that runs on any of your Macs. Without it: ad-hoc sign and right-click-open (fine for personal use, but Screen Recording permission nags more).
- Build script: `xcodebuild archive` → `notarytool` → `create-dmg`.
- Optional: Sparkle for auto-updates from a GitHub Releases feed.

**Done when**: you download the DMG on a second Mac, drag to Applications, and it records a meeting.

## Risks / gotchas

- **Screen Recording permission** is mandatory for system audio and looks scary; the app never captures video — say so in the permission prompt copy.
- **Deepgram costs** ~ $0.46/hr streamed ×2 streams; Claude enhancement pennies per meeting. Budget ~$1/meeting-hour.
- **macOS updates** occasionally reset screen-recording permission; detect and re-prompt.
- **App Store** distribution is off the table (system audio capture), Developer ID only.

## Suggested order of prompts to Claude Code

1. "Set up Phase 0 per granola-clone-plan.md" … then one phase per session, testing each Done-when gate before moving on. Keep the plan file in the repo root so Claude Code can reference it.

Total estimate: ~10–12 working days of Claude Code sessions.
