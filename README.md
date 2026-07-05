# Oatmeal

A native macOS meeting notepad with live transcription and AI-assisted notes.
Record microphone and system audio, keep a scratchpad during a meeting, and turn
the transcript into editable notes. No meeting bot joins the call.

Oatmeal stores recordings and notes locally. Transcription sends audio to Deepgram;
AI features send meeting text to Anthropic. Bring your own API keys and review
[privacy and data handling](docs/privacy.md) before recording.

## Features

- Microphone and system audio capture, live level meters, pause/resume, and a menu bar control.
- Live transcripts with speaker labels, editable speaker names, and audio playback.
- Notes, Transcript, and Scratchpad tabs, with a readable Markdown view and follow-up checkboxes.
- Standard, Interview, 1:1, Sales Call, and Standup note templates.
- Search across meeting titles, transcripts, and notes; an aggregated Action Items view.
- Calendar integration through macOS Calendar accounts, with upcoming meetings and call links.
- Optional meeting-end reminders with a countdown before stopping.
- Local audio recovery through re-transcription and resumable pending note generation.

## Get started

Oatmeal currently ships as source for **macOS 14 or later**. The package declares
Swift tools 5.10; the tested development toolchain is Swift 6.3. Use Xcode with a
compatible macOS SDK for development and the XCTest suite. Command Line Tools can
build the application and run the standalone presentation checks.

```sh
git clone https://github.com/tzglobic/Oatmeal.git
cd Oatmeal
bash Scripts/build-app.sh release
open .build/Oatmeal.app
```

In **Settings (⌘,)**, save and validate a Deepgram key and, for AI features, an
Anthropic key. Grant microphone and system audio permissions when prompted.
See [installation and setup](docs/installation.md) for details and signing options.
API usage is billed by the providers; Oatmeal does not include service credits.

## Documentation

- [Installation and setup](docs/installation.md)
- [User guide](docs/user-guide.md)
- [Privacy, storage, and backups](docs/privacy.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Architecture and development](docs/development.md)
- [Code signing](docs/signing.md)
- [Contributing](CONTRIBUTING.md) · [Security reporting](SECURITY.md)

## Project status

Oatmeal is an early-stage macOS application. Automated checks cover recording
lifecycle, persistence, reconnect behavior, and presentation helpers. Real device
permissions, capture, and playback still require manual testing. There is no
packaged notarized release or automatic updater in this repository.

Chat, briefs, recipes, cloud synchronization, and Linux/Windows support are not
implemented. AI-generated notes and speaker names should be reviewed for accuracy.

## Development

```sh
swift build
swift test
bash Scripts/check-presentation.sh
swift build -c release
```

`swift test` requires XCTest, normally supplied by Xcode. See the
[development guide](docs/development.md) for test boundaries and a manual checklist.

## License

[MIT](LICENSE). Dependencies retain their respective licenses.
