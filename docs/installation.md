# Installation and setup

## Requirements

- macOS 14 or later. The application uses SwiftUI, EventKit, AVFoundation, and ScreenCaptureKit.
- A Swift toolchain and macOS SDK. `Package.swift` declares tools version 5.10;
  development and CI are validated with Swift 6.3. Older toolchains are not covered by CI.
- Xcode for the XCTest suite, or Command Line Tools to build the app.
- A Deepgram API key to start recording and transcribe audio.
- An Anthropic API key for note generation, automatic titles, and AI speaker identification.
- Internet access for dependency downloads and API features.

## Build the app

From the repository root:

```sh
swift --version
xcrun --show-sdk-path
bash Scripts/build-app.sh release
open .build/Oatmeal.app
```

Omit `release` for a debug build. The script uses `swift` from your `PATH`, the
selected SDK, and ad-hoc signing by default. It does not search for personal
certificates or select an installed custom toolchain on your behalf.

To select a toolchain executable explicitly:

```sh
SWIFT=/path/to/toolchain/usr/bin/swift bash Scripts/build-app.sh release
```

`SDKROOT` can override the SDK path. `OATMEAL_SIGNING_IDENTITY` can select a code
signing identity; see [signing](signing.md). The bundle is built for the host
architecture; the script does not produce a universal binary or installer.

Launch the `.app` bundle rather than the bare SwiftPM executable so macOS can use
the bundle's permission descriptions. Quit before rebuilding or replacing it.
You can copy the bundle to Applications for regular use; use one installation
location consistently when diagnosing permission problems.

## First launch

1. Open **Settings (⌘,)** and enter the API keys under their respective providers.
2. Select **Save & Validate** for each key. Validation checks authentication, not
   model entitlement, available credit, or every later API request.
3. Select **Start recording**. Allow microphone access for your voice and
   Screen & System Audio Recording access for other participants' audio.
4. After changing system audio permission, quit and reopen Oatmeal.
5. Check that the Mic and System meters respond during a short test recording.

Recording can continue with one audio source if the other is unavailable; inspect
warnings and level meters. A Deepgram key is required by the current recording flow
even if you only want to keep the local audio file.

## Calendar and notifications

Calendar access enables Up Next, event titles, and attendee suggestions. Oatmeal
reads accounts available through macOS Calendar/EventKit. Add the calendar account
in System Settings → Internet Accounts and enable its calendars. Accounts used
only inside a separate calendar application may not be visible to EventKit.

Notifications provide meeting-start actions and meeting-end prompts. Calendar and
notification access are optional; manual recording remains available. Permission
names and settings locations vary by macOS version.
