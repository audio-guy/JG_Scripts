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
  Use the planned slot start even when pre-roll is enabled; preserve user names in data.
- Keep scheduling independent of window visibility and bound to the original project.
- Never imply gapless folder changes: separate slots stop/start; continuous adjacent
  slots retain the first slot's folder and add markers.
- See `docs/recording-scheduler.md` for behavior, recovery and host-test requirements.
