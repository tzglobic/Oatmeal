# Troubleshooting

## Build or test errors

Confirm `swift --version` and `xcrun --show-sdk-path`. Use the tested Swift 6.3
toolchain and a compatible macOS SDK. The build script honors `SWIFT` and `SDKROOT`;
it no longer chooses a custom toolchain from a developer's home folder.

If `swift test` reports that XCTest cannot be found, select a full Xcode developer
directory. Command Line Tools alone may not supply XCTest. The standalone
`bash Scripts/check-presentation.sh` checks presentation helpers, not the full suite.

## Permission granted, but capture is unavailable

Open Settings → Health, refresh, and inspect macOS Privacy & Security settings.
Quit and reopen after changing Screen & System Audio Recording permission. Confirm
that the entry refers to the app bundle you are actually running. Rebuilding with
ad-hoc signing or changing signing identity/location can require a new grant; see
[code signing](signing.md).

## Missing microphone or remote audio

Check the Mic and System meters separately. Select a working microphone in macOS
Sound settings and confirm permission. Oatmeal can record system audio without a
microphone, or microphone audio when system capture fails; a warning explains the
missing source. If neither source starts, recording fails.

The audio capture code validates microphone formats before installing a tap;
missing or invalid input devices should produce an error rather than an invalid
audio tap. Include device type and OS version in a redacted bug report.

## Transcript gaps or connection errors

Check internet access, the Deepgram key, account limits, and the connection status.
Reconnect buffering is bounded (up to roughly sixty seconds); long outages can
leave gaps. If the saved audio is intact, use **Re-transcribe from Audio**. This
sends the recording again and incurs API usage.

## Notes fail to generate

Validate the Anthropic key, check provider access/credit and the displayed error,
then retry Generate notes. A valid key does not guarantee access to the model
configured in `AIService.swift`. Raw notes and the saved transcript remain available.
AI output and inferred names may be incorrect and can be edited.

## Calendar events are missing

Confirm the account appears in macOS Calendar and calendar access is granted.
Up Next excludes all-day, canceled, ended, and explicitly declined events and
covers today and tomorrow. A separate calendar client's private account store is
not necessarily available to EventKit.

## Save errors or Quit is refused

Check free disk space and access to the application support folder. Avoid deleting
files or database sidecars while the app is running. Retry after resolving the
underlying problem; forcing Quit can discard unsaved edits. Copy visible unsaved
text somewhere safe before further troubleshooting.

## Reporting a problem

Include macOS version, architecture, Swift version for build issues, the commit
or release, reproduction steps, and expected/actual behavior. Use synthetic meeting
content. Do not attach API keys, a meeting database, private recordings, attendee
lists, or unredacted exception logs. See [contributing](../CONTRIBUTING.md).
