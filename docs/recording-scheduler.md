# Recording Scheduler 2.1

## Purpose and product decisions

For unattended audio recordings and attended live capture, not studio workflows.
The scheduler must not depend on window visibility. A missed or unverified recording
must never be presented as completed. User slot names are preserved verbatim.
All generated slot folder/marker/tag names use **YYMMDD - HHMM Name**, for example
`261102 - 1930 Konzert`. The date/time is the planned start, not the pre-roll start.
Only the filesystem-derived name replaces invalid filename characters.

## Installation

Load `Tools/JG_Recording_Scheduler.lua` through REAPER's Actions list. Requires
ReaImGui 0.10 or newer (available through ReaPack). SWS is not required by this version.
Close any running older scheduler before launching the new one. Version 1 kept its
plan only in memory, so there is no saved v1 plan to import.

The development installation can point existing action paths to this file with a
symbolic link. The repository file is the maintained source. This version is not
added to the public ReaPack index until a release is explicitly requested.

## Interface

The main view opens on **Schedule**. A persistent header shows recording state,
the next slot/countdown and the enable/stop controls. Project, armed-track count
and recording mode remain visible across all three views.

- **Schedule:** a scrollable table with fixed headers and separate date, start,
  end, length and status columns. Select a row for Edit, Duplicate and Delete.
  Completed/stopped history is hidden initially; failed/missed/partial entries
  stay visible. Expand Selected slot details for the recording window and folder.
- **Add slot / Edit selected:** opens an inline editor in place of the table.
  Dates and times are paired; repetition, margins and templates are collapsed
  until needed. Save returns to the plan; Cancel discards the draft. Switching
  views retains an unfinished draft and prevents enabling until it is resolved.
- **Setup:** destination, recording mode and four explicit operator checks.
- **Activity:** all events, newest first, with a log export button.

The interface uses 16 px text, consistent control spacing and keyboard navigation.
Scheduling remains independent of the selected view and window visibility.

## Before enabling

1. Save the REAPER project and arm the intended audio input tracks.
2. Use normal project recording mode and `Record: input` on each armed track.
3. Disable recording-length limits, count-in/pre-roll in REAPER, and looping.
4. Configure REAPER to retain recorded files without a confirmation dialog.
5. Check audio routing, gain, available disk space and power. Prevent system sleep.
6. Confirm the setup in the scheduler. This is an operator check, not an automatic
   guarantee of the project's recording settings, disk capacity or signal quality.
7. Add future slots and explicitly select **Enable schedule**.

The automatic readiness check verifies a saved/selected project, stopped transport,
at least one armed audio-input track, an open audio device and disabled looping.
All planned target folders are created and write-tested when enabling, and the
actual target is checked again at recording start. It does not reserve disk space.
Tracks/routing are read at each start; keep the intended tracks armed throughout.

The scheduler binds to the project in which it was opened. Switching project tabs
disables future starts. An owned recording still retains its scheduled stop in its
original project. Existing manual recordings are never taken over.

## Recording folders and continuous live capture

The blank root setting uses the project's effective recording path. A custom root
may be absolute or relative to the saved project directory. Each slot's generated
subfolder is `YYMMDD - HHMM Name`. The final path is shown during recording and in
the activity log. Folder names are generated, not arbitrary paths supplied by slot
names. Existing folders are reused; REAPER remains responsible for unique audio
filenames. The slot name is also exposed as REAPER's `$rectag` wildcard. To include
it in individual audio filenames, configure `$rectag` in REAPER's recording filename
pattern; this script does not change global filename preferences.

- **Separate recordings (default):** one folder per slot; each slot stops and the
  next starts. This transition can leave a gap. Do not use it for uninterrupted
  event capture.
- **Continuous live recording:** exactly adjacent recording windows remain in one
  uninterrupted transport recording, in the **first slot's folder**. Later slots
  create markers rather than new audio files. Final verification happens after the
  entire continuous session stops. A real gap between slots ends the session.

Adjacency and conflicts include pre-roll and post-roll. Overlapping windows are
rejected with the affected names; the previous destructive Merge/Trim shortcuts
were removed. Adjust the displayed times or use a single longer slot.

The script temporarily changes only the target project's recording path and tag,
then restores the previous values after stopping. If an external edit changes those
settings during recording, that change is preserved. Recordings append at the later
of the edit cursor and existing project end, avoiding wall-clock seeks into media.

## Planning and live operation

- Dates: `YYMMDD` (also accepts `YYYY-MM-DD`). Times: `HH:MM` or `HHMM`.
- End date is explicit, including overnight recordings. End must follow start.
- **Open-ended recording** is an explicit option and requires a manual stop.
- Pre-roll/post-roll: whole seconds from 0 to 3600.
- Repetition: 1–100 occurrences, daily or weekly at the same local time.
- Ambiguous/nonexistent daylight-saving times are rejected, including repetitions.
- Duplicate an existing slot, choose a new time and save.
- Templates preserve the slot name, times, margins and end-day offset in this project.
- Disable future starts before changing the plan. Active slots cannot be deleted or
  edited. Their end can be extended by five minutes if no future slot conflicts.
- One-level undo restores the last add/edit/delete/template change.
- **Disable schedule** (or **Disable future starts** while recording) leaves an active recording's stop time intact.
- **Stop recording** ends the owned recording immediately.
- Closing an active/enabled scheduler asks explicitly to stop and close or keep running.
  Terminating the script also attempts to stop only its own recording and restore settings.

## Persistence and results

Plans/templates/logs are stored in project extstate and immediately in a
`<project>.rpp.jg-scheduler` recovery file next to the saved project. Save the REAPER
project normally to embed current extstate; the sidecar preserves more recent plan
changes independently. Keep the sidecar with the project. Saves use a temporary file
and rename; a failed save disables future starts and reports the error. Corrupt data
is not overwritten automatically.

Reopening always leaves scheduling disabled. Previously active entries become
**Interrupted**, not completed. Review their files before duplicating/rescheduling.
There is no autonomous restart of REAPER or recovery from a machine crash.

| Status | Meaning |
|---|---|
| Scheduled | Planned; only starts when the schedule is enabled |
| Recording | Active, or part of a continuous session awaiting final verification |
| Completed | Transport ran and new nonempty files with positive source duration were found in the target folder on every expected track |
| Partial | Files found, but timing was late or the system clock changed; inspect the result |
| Stopped | A recording ended through manual intervention or script closure |
| Missed | The start was more than five seconds late, or its entire window elapsed |
| Failed | Start or file verification failed; inspect the project and disk |
| Interrupted | A previous scheduler session ended without a verified result |

Completion does **not** verify signal, audible content, full duration, absence of
underruns or file integrity. Pre-existing files and unrelated new files outside the
slot folder are excluded from verification. In continuous mode verification covers
the whole transport session, not an individual file per slot. The activity log lists
confirmed new file paths. The Activity view and export include all events.

**Export log** writes `<project>.rpp.recording-log.tsv`, replacing a previous
export for that project. The versioned text format escapes tabs/newlines/percent
characters in user content rather than executing stored data.

## Timing and host limitations

Timing uses system wall time and REAPER's deferred script loop, not an audio-thread
or sample-accurate clock. A blocked REAPER UI, modal dialog, sleep, crash or audio
hardware failure can interrupt automation. Starts over five seconds late are marked
missed. Small delays and late stops are recorded as partial results. System-clock
jumps disable future starts and flag active timing for review; active stops retain
their wall-clock deadline. Test your exact host settings before an unattended event.

## Verification

```sh
TZ=Europe/Berlin lua tests/recording_scheduler_test.lua
TZ=Europe/Berlin lua tests/recording_scheduler_host_test.lua
luac -p Tools/JG_Recording_Scheduler.lua
```

Tests run real parsing, storage, state-machine, adapter and window-loop code with a
mock REAPER host. They cover malformed dates, DST, overlap/recurrence, persistence,
missed/failed starts, ownership, close/stop behavior, continuous vs separate sessions,
folder restoration and file verification. They do not replace a real audio session.

Manual acceptance before unattended use: a short test with two slots in each mode,
window collapsed, one deliberate manual stop, one restart/recovery and project tab
switch; verify file destinations, recorded duration and audio on every intended track.

API reference: [REAPER ReaScript documentation](https://www.reaper.fm/sdk/reascript/reascripthelp.html),
particularly `Main_OnCommandEx`, `OnStopButtonEx`, `GetPlayStateEx`, `GetProjectPathEx`,
`GetSetProjectInfo_String` (`RECORD_PATH`, `RECTAG`) and project extstate.
