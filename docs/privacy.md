# Privacy and data handling

Oatmeal has no application backend or account system. Local storage does not make
its transcription and AI features offline: they contact external providers.

## Data destinations

| Destination | Data and purpose |
| --- | --- |
| Local application support folder | Meeting metadata, transcripts, scratchpads, enhanced notes, pending enhancement jobs, audio recordings, and exception diagnostics. |
| macOS Keychain | Deepgram and Anthropic API keys under service `com.oatmeal.app`. |
| Deepgram | Captured microphone/system audio for live transcription; the saved audio file when re-transcribing. Key validation also contacts Deepgram. |
| Anthropic | Scratchpad and transcript text for notes and titles; transcript excerpts and calendar attendee names for speaker identification. Key validation also contacts Anthropic. |
| macOS Calendar/EventKit | Reads events to show upcoming meetings, associate recordings, and supply titles/attendees. |

The current implementation contains no analytics or crash-upload service.
Provider data retention and account controls are governed by the provider's terms
and your account settings; Oatmeal does not configure them. Recording and AI
features can incur API charges. Automatic enhancement can send meeting text after
Stop and retry pending work when the app starts.

System audio capture can include sounds from applications other than the meeting.
ScreenCaptureKit supplies audio; Oatmeal does not persist screen video or images.
Inform participants and obtain the permissions needed for your context before
recording or sending meeting content to external services.

## Storage and backups

Data is stored under `~/Library/Application Support/Oatmeal/`:

- `oatmeal.sqlite`, with any SQLite sidecar files: meeting records and text.
- `Recordings/`: stereo `.m4a` files, with microphone on the left and system audio on the right.
- `last-exception.log`: the most recent captured Objective-C exception diagnostic.

The database and audio are not encrypted by Oatmeal. Access depends on the macOS
account, filesystem permissions, and disk protection. Diagnostics may contain
local paths or contextual details; inspect and redact them before sharing.

Quit Oatmeal successfully before backing up the entire folder. Keep the database
and recordings together. Audio paths are stored as absolute paths, so moving a
backup to another account or location may require path repair; the app has no
backup import or relocation tool. API keys are separate Keychain entries and are
not included in a folder backup.

## Removal

Deleting a meeting removes its local records and attempts to remove the audio file.
If audio deletion fails, the app reports the error; inspect the reported file.
Local deletion does not delete data already sent to a provider or copied into a
backup. There is no secure-erasure feature.

To remove all local app data, quit, remove the app and its application support
folder, and remove the two API-key entries for `com.oatmeal.app` in Keychain Access.
Removing the app alone does not remove recordings, settings, or keys. The current
Settings UI cannot save an empty key; use Keychain Access to remove keys and revoke
them with their providers when needed.
