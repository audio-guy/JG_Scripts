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
- Every slot must create its own subfolder inside the selected recording folder.
  No continuous/shared-folder mode. Stop/start can leave a gap.
- See `docs/recording-scheduler.md` for behavior, recovery and host-test requirements.

- Keep the Scheduler main view focused on status and the schedule. Put configuration
  in Setup, logs in Activity, and slot editing behind an explicit action. Keep
  the editor free of templates; use Duplicate for similar slots and avoid per-row button clusters.
- No occurrences/repetition, pre/post-roll controls or mandatory setup checklist.
  Use direct recording start/end times and duplicate slots when needed.
- Offer a native folder picker for the recording destination.
- Always show the running Scheduler version in the window title. Keep it in sync
  with the script's ReaPack version; preserve the ImGui window ID across updates.

- Treat the Scheduler as an expert operator tool: no onboarding paragraphs in the
  main view, no admin/guest split, concise labels and a single actionable message
  area. Confirm closing only when it would stop an active recording. Keep technical
  readiness, time, project and destination checks intact.

- Saving a valid future slot schedules it automatically. No separate Enable step.
  Allow adding/editing slots while waiting; protect active recording and destination
  changes. Preserve an explicit Pause across reopening. Show save validation next
  to the form action and retain rejected drafts.
