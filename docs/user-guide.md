# User guide

## Record a meeting

Choose **Start recording**, use the menu bar control, or select Record beside an
Up Next event. Recording a calendar event uses its title and attendee list. A
manual recording can associate with a currently active calendar meeting.

The capture bar shows recording state, elapsed time, microphone/system levels,
and transcription connection status. **Pause** silences capture while the clock
continues, preserving timestamp alignment. **Resume** continues capture.

Use **Stop & Save** when finished. Oatmeal drains audio, finalizes the `.m4a`, and
waits briefly for trailing transcript results. Start/stop controls are disabled
while startup or saving is in progress. If available, AI enhancement starts after
recording even when a different meeting is selected.

## Notes and follow-ups

- **Scratchpad:** type rough notes before or during the meeting; changes autosave.
- **Notes:** read enhanced Markdown, toggle follow-up checkboxes, or select
  **Edit notes** to edit the Markdown source. **Done** flushes your edits.
- **Transcript:** review speaker-labeled text and play the associated audio.

Choose Standard, Interview, 1:1, Sales Call, or Standup, then **Generate notes** or
**Regenerate**. Regeneration replaces the enhanced note using the scratchpad and
transcript; copy any enhanced-note edits you want to preserve first. Changing a
template alone does not regenerate the note. **Copy** copies the current tab.

The Action Items sidebar entry gathers Markdown checkboxes across enhanced notes.
Checkboxes inside fenced code examples are excluded. Toggling an item updates its
source note. The readable Notes view also shows follow-ups beside the note, or in
a collapsible section when the window is narrower.

## Transcripts and speakers

Click a transcript timestamp or line to seek the recording. Playback controls let
you pause and scrub. Click a speaker label to rename it, or use **⋯ → Speakers…**
for all detected speakers and attendee suggestions. **Identify with AI** infers
names from transcript context; verify the results. Automatic identification after
note generation preserves names entered manually.

**⋯ → Re-transcribe from Audio** sends the saved recording to Deepgram and rebuilds
the transcript. It requires an existing audio file and incurs provider usage.
This is useful after network interruptions; review the regenerated transcript.

## Find and organize meetings

The sidebar groups meetings by Today, This week, and Earlier. Search covers titles,
transcripts, and notes. Rename a meeting in its title field or sidebar context menu.
Delete Meeting removes its database records and attempts to delete the associated
audio. There is no undo or trash recovery in the app; back up important meetings.

Up Next offers Join for recognized HTTPS Teams, Zoom, Google Meet, and Webex links.
Join opens the URL with macOS; recording still needs to be started explicitly.

## Meeting-end reminders

The Recording setting enables end detection. Oatmeal prompts when a calendar event
has ended by at least two minutes and both channels have been quiet for three
minutes, or after fifteen minutes of sustained silence. The prompt appears in the
app and, when permitted, as a notification.

Choose **Keep Recording** to snooze detection for ten minutes, or **Stop & Save**.
If unanswered for sixty seconds, recording stops. New audio activity cancels the
countdown. Pausing holds the silence clock; disabling the setting cancels pending
prompts. Silence detection is a heuristic, so check recording state during quiet
meetings.

## Save failures and quitting

Errors appear in the app rather than being treated as successful saves. Keep the
app open and resolve disk or permission problems if notes cannot be saved. Normal
Quit waits for audio finalization and local saves; it can be refused if data is
still unsaved. Force quitting can lose unsaved work.

Pending automatic enhancement jobs persist and are retried at launch. Quit does
not wait indefinitely for AI requests. Missing keys or provider errors can leave
a job unfinished; resolve the issue and regenerate or restart the app.
