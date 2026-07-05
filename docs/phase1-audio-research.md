# Phase 1 research — audio capture + Deepgram streaming

Engineering brief gathered 2026-07-05 to inform Phase 1 (recording + live transcript).
Read this before implementing `AudioService` / `TranscriptionService` streaming.

## Key decisions vs. the original plan

1. **One Deepgram WebSocket, not two.** The plan called for two parallel streams
   (mic + system). Deepgram supports `channels=2&multichannel=true` on a single
   socket: interleave mic (ch 0) and system audio (ch 1) into one stereo linear16
   stream and each channel is transcribed independently — free "Me/Them" speaker
   attribution, one connection to manage. Billing is per channel, so cost is the
   same (~$0.92/hr PAYG for both channels), but reconnect logic is halved.
2. **System audio: ScreenCaptureKit first, CoreAudio process taps as a follow-up.**
   SCK is the battle-tested path but requires the full Screen Recording permission
   (and macOS 15 re-prompts ~every 30 days). CoreAudio taps (`CATapDescription` +
   `AudioHardwareCreateProcessTap`, macOS 14.4+) show under the softer
   "System Audio Recording Only" TCC entry but have no public permission-request
   API and reported reliability issues on some macOS 15 builds. Ship SCK, feature-
   flag taps later. Reference implementation: github.com/insidegui/AudioCap.

## ScreenCaptureKit audio-only capture

- `SCStreamConfiguration`: `capturesAudio = true`, `excludesCurrentProcessAudio = true`,
  `sampleRate = 48_000`, `channelCount = 1`; give video throwaway dimensions
  (width/height = 2, 1 fps) and drop video callbacks — SCK always has a video pipeline.
- `SCContentFilter(display:excludingApplications:[]:exceptingWindows:[])` for full system audio.
- `stream.addStreamOutput(self, type: .audio, sampleHandlerQueue:)`; buffers arrive as
  Float32 non-interleaved PCM at the configured rate via
  `stream(_:didOutputSampleBuffer:of:)` — unwrap with `sampleBuffer.withAudioBufferList`.
- Permission: Screen Recording TCC (no Info.plist key; purple indicator shows).
- macOS 15 adds `captureMicrophone` + `.microphone` output — one SCStream could deliver
  both channels if we require 15+ later.

## Mic capture (AVAudioEngine)

- Tap must use the hardware format (typically 48kHz Float32) — you cannot request
  16kHz in `installTap`. Convert with a single reused `AVAudioConverter` to
  `.pcmFormatInt16 / 16_000 / 1ch / interleaved`.
- Converter input block must serve each buffer exactly once (`.noDataNow` after),
  or you get glitches/loops. The converter handles downmix + Float32→Int16 in one pass.
- Same converter pattern applies to the SCK 48kHz Float32 buffers.

## Deepgram live streaming (verified mid-2026)

- Endpoint: `wss://api.deepgram.com/v1/listen`
- Auth: `Authorization: Token <API_KEY>` header (fine on URLSessionWebSocketTask).
- Model: `nova-3` (still current flagship; `flux` is for voice agents, not meetings).
- Recommended query string:
  `model=nova-3&encoding=linear16&sample_rate=16000&channels=2&multichannel=true&interim_results=true&smart_format=true&endpointing=300`
  (add `diarize=true&diarize_model=latest` if per-channel diarization is wanted; the
  plain `diarize` boolean is deprecated but send both for safety).
- Keepalive: TEXT frame `{"type":"KeepAlive"}` every 3–5s during silence, or the
  connection dies with NET-0001 after ~10s. `{"type":"Finalize"}` flushes,
  `{"type":"CloseStream"}` closes gracefully. Silence + keepalives are not billed.
- Results: `"type":"Results"` messages; `channel_index[0]` = channel;
  `is_final=false` → interim (replace current line), `is_final=true` → persist segment,
  `speech_final=true` → utterance boundary. Words carry start/end/confidence/punctuated_word.
- Pricing: ~$0.0077/min per channel PAYG (≈ $0.46/hr/channel).
- Key validation (already implemented in TranscriptionService):
  `GET https://api.deepgram.com/v1/auth/token` with `Authorization: Token <key>` — free;
  200 = valid, 401 = invalid.
