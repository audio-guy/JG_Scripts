# JG_Scripts project rules

## Language

- All JG scripts must use English consistently: window titles, labels, buttons,
  tooltips, dialogs, errors, status messages, undo descriptions, and generated
  PDF/text/export headings and summaries.
- Write script descriptions, help text, comments, and new changelog entries in English.
- New built-in examples and default text must be English.
- Preserve user content verbatim, including project/track/item/marker/region
  names, preset names, and saved filter patterns. Do not translate user data or
  rewrite saved matching rules merely to change the interface language.
- Keep communicating with Julius in German.

## Verification

- When changing shared output text, check the interface and all export paths,
  especially PDF headings. Do not assume the preview and PDF share their labels.

## Recording Scheduler

- Target unattended recordings and attended live capture, not studio workflows.
- Generated slot folder, marker and recording-tag names use `YYMMDD - HHMM Name`.
  Use the slot start; preserve user names in data.
- Keep scheduling independent of window visibility and bound to the original project.
- Separate slots is the only available recording mode. Migrate saved Continuous /
  Shared WAV plans to separate slots; no recording-mode selector. Clock-aligned
  live items take priority over sharing one source file. Preserve historical capture
  metadata and original audio from earlier shared recordings. No band-folder export;
  each new slot already records directly into its own folder.
- Separate slots stop/start into their own folders; transitions can leave a gap.
- See `docs/recording-scheduler.md` for behavior, recovery and host-test requirements.

- Keep the Scheduler main view focused on status and the schedule. Keep logs in an optional Activity log window,
  and slot editing behind an explicit action. No navigation tabs or Recording help. Keep
  the editor free of templates; use Duplicate for similar slots and avoid per-row button clusters.
- No occurrences/repetition, pre/post-roll controls or mandatory setup checklist.
  Use direct recording start/end times and duplicate slots when needed.
- Record each slot into a subfolder beside the saved RPP. Do not use the project
  media path or legacy destination overrides. No recording settings or folder picker.
- Always show the running Scheduler version in the window title. Keep it in sync
  with the script's ReaPack version; preserve the ImGui window ID across updates.

- Treat the Scheduler as an expert operator tool: no onboarding paragraphs in the
  main view, no admin/guest split, concise labels and a single actionable message
  area. Confirm closing only when it would stop an active recording. Keep technical
  readiness, time, project and destination checks intact.

- Saving a valid future slot schedules it automatically. No separate Enable step.
  Allow adding/editing slots while waiting; protect active recording and destination
  changes. Always watch the plan while open; no Pause/Resume controls or saved pause
  state. Keep safety holds for clock/storage errors. Show save validation next
  to the form action and retain rejected drafts.

- Place scheduled recordings by clock time relative to a persisted midnight reference
  day, respecting project time offsets. Never append based on cursor/project length.
  Keep following days chronological and reject collisions on armed tracks.

- A blank end time means open-ended recording; no Open end checkbox. Nonblank
  invalid times remain errors. Offer to shorten a scheduled predecessor at a new
  slot's start only with explicit confirmation; apply both changes atomically.
- Ordinary playback must not block scheduled recording: stop it before positioning
  and starting. Never stop or take over an existing recording.

- Double-click editable schedule rows to open their editor. Date/time field pairs
  share label and input table rows so their baselines remain aligned.

- Allow editing the currently recording slot's name and end, with a fixed start.
  Update its linked region and effective stop together; reject past ends/overlaps.
  No Extend by 5 min control. Keep historical slots and active transport protected.

- Blank names default to Slot N using the slot number. Allow Add slot during recording. Each added slot retains its independent folder. Confirm any predecessor shortening
  and validate overlaps before changing the running plan or its regions.

- Confirm directly adjacent slots when saving, including live end edits. Use
  "will cause a brief interruption", never "may". Offer Save anyway / Keep editing;
  Enter must not confirm. Show the same notice with overlap-shortening confirmation.
  Never interrupt unattended recording with a transition-time dialog.

- Support audio and MIDI inputs in Record: input mode, including mixed sessions.
  Verify new MIDI takes/events independently of audio files; never count existing
  takes. Preserve REAPER's MIDI storage preference and save the named project after
  MIDI capture, restoring the recording destination first. Report save failures.
- Do not show a redundant Separate slots mode line in the main header.
- Hide the empty transport header; no Idle / No upcoming slots line when no recording
  is active or scheduled.
- Enter/keypad Enter in the focused schedule overview opens Add slot with name focus.
  In the editor it saves; never reuse the opening keypress to submit the new form or
  trigger Stop recording. Keep adjacency/overlap confirmations explicit.
