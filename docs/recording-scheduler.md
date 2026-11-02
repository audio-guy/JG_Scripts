# Recording Scheduler 2.4.3

## Purpose

For unattended audio recordings and attended live capture, not studio workflows.
The main view stays focused on the schedule. Each slot has direct start/end times
and always records into its own subfolder. No repetition, pre/post-roll controls,
continuous/shared-folder mode or confirmation checklist.

## Installation and use

Load `Tools/JG_Recording_Scheduler.lua` in REAPER's Actions list. Requires ReaImGui
0.10 or newer. The optional js_ReaScriptAPI extension supplies the native folder
picker; without it, the destination can still be entered manually.

1. Save the project and arm the intended audio input tracks.
2. In **Setup**, choose the recording destination with **Choose folder...**.
   **Use project folder** uses the effective project recording path instead.
3. In **Schedule**, select **Add slot**, enter a name, start and end, and save.
   For overnight recordings, enter the next end date. **Open end**
   explicitly leaves the end to a manual stop.
4. Saving schedules the slot automatically. Use Duplicate to add another similar slot.
   **Pause schedule** suspends future starts; **Resume schedule** restores them.

Dates use `YYMMDD`; times use `HH:MM` or `HHMM`. Seconds (`HH:MM:SS`) are accepted
for exact legacy timing. Invalid and ambiguous daylight-saving times are rejected.
Overlaps are rejected without changing the existing plan.
Saving a slot or resuming requires a saved REAPER project. A rejected draft stays
open so it can be saved after saving the project. Readiness issues are shown before
the first start; the start-time safety check still runs.
Missed slots that never started recording can be edited and saved with a new future
start, including when the original start passes while the editor is open. Slots
that already ran or attempted to record retain their history; use Duplicate instead.

## Recording destination

The selected folder is the parent; each slot creates a subfolder inside it:

```text
Selected recording folder/
  261102 - 1930 Concert/
  261102 - 2100 Encore/
```

Folder, marker and recording-tag names follow **YYMMDD - HHMM Name**. User names
are kept verbatim in the plan. Only derived filesystem names replace forbidden
characters. A manually entered root can be absolute or relative to the saved
project directory. Cancelling the native folder dialog preserves the previous root.
Existing slot directories are reused; REAPER supplies unique audio filenames.

Each slot stops and the next starts, even when adjacent. This can leave an audio
gap. Use one longer slot for uninterrupted event capture. The previous continuous
mode is no longer used, including when loading older plans.

The slot name is also supplied through REAPER's `$rectag` wildcard. To include it
in individual audio filenames, add `$rectag` to REAPER's recording filename pattern.
The script does not change global naming preferences.

## Interface

The window title shows the running version (for example, Recording Scheduler v2.4.0).
Restart the script after updating to load the new version. This identifies the
loaded version; it does not check online for updates.

The UI is designed for an experienced operator. The compact header shows state and
next/active slot; one message area displays concrete issues across every view.
Explanations live under Recording help, not in the primary workflow. Technical
checks remain enforced. There is no admin/guest distinction.


- **Schedule:** next recording/countdown, transport controls and scrollable plan.
  Select a row for Edit, Duplicate or Delete. Completed/stopped entries are hidden
  initially; failures remain visible. Show history reveals past entries.
  Delete removes any inactive slot from the plan, including failed and completed
  slots. It never deletes audio files. Undo restores the removed entry.
- **Slot editor:** name, dates and times. Use Duplicate for similar slots. Save returns to the plan; Cancel discards the draft. Switching views
  preserves the draft. Existing slots keep running on schedule while you plan another.
- **Setup:** recording folder and optional recording help.
- **Activity:** all events and verified file paths, newest first; Export log writes
  `<project>.rpp.recording-log.tsv` and replaces the previous export.

Plan changes are allowed while waiting for scheduled starts, but locked during an
active recording. Pause scheduling before changing the destination folder. The active end can be extended by five minutes if it
does not conflict with another slot. Undo restores the last plan change.
Pause schedule leaves an active recording's scheduled stop intact. Stop recording
stops the owned recording and disables future starts. Closing during an active recording asks whether to stop and close or keep running.
Otherwise closing directly disables future starts and retains the plan.

## Readiness and limitations

The automatic check verifies the saved/selected project, stopped transport, armed
audio-input tracks, open audio device, and disabled looping. Destination folders
are created and write-tested at each actual start. Existing manual
recordings are never taken over. Recording appends after existing project content.

There are no mandatory confirmation checkboxes. The operator still needs normal
record mode, no recording-length limit/count-in, automatic retention of recorded
files, correct routing/levels, sufficient disk space and a computer that stays awake.
Those conditions are explained under Recording help; they are not all measured
by the script. Writing a small probe file does not reserve disk space.

The scheduler is bound to its original project. Changing project tabs disables
future starts; an owned recording keeps its scheduled stop in the original project.
Window visibility and selected GUI view do not affect scheduling.

Timing uses system wall time and REAPER's deferred loop, not an audio-thread clock.
Blocking dialogs, sleep, crashes and device failures can interrupt automation.
Starts over five seconds late are missed; late stops or clock changes require review.

## Persistence and migration

Plans and logs are stored in project extstate and an immediate recovery
sidecar, `<project>.rpp.jg-scheduler`. Save the project normally to embed the extstate;
keep the sidecar with the project. Failed recovery-file writes disable future starts.
Corrupt data is preserved for recovery instead of overwritten.

Reopening automatically watches future slots unless you explicitly paused the plan.
An explicit pause is retained across reopening. Past starts become Missed; previously
active slots become Interrupted. Old repeated entries remain as individual slots. Pending legacy slots
with pre/post-roll are converted to visible direct start/end times, preserving the
actual recording window including seconds. Completed history retains its original
times. Duplicating legacy history exposes its effective times in the editor rather
than silently applying hidden margins. Legacy template data remains readable and
is preserved for compatibility, but templates are no longer available in the UI.

## Results

| Status | Meaning |
|---|---|
| Scheduled | Starts automatically at the planned time unless paused |
| Recording | The slot is recording |
| Completed | New nonempty files with positive source duration found on every expected track |
| Partial | Files found, but timing was late or the system clock changed |
| Stopped | Recording stopped through manual intervention or script closure |
| Missed | Start more than five seconds late, or entire window elapsed |
| Failed | Start or file verification failed |
| Interrupted | Previous scheduler session ended without a verified result |

Completed does not verify signal quality, full duration, underruns or file integrity.
Pre-existing files and new files outside the slot folder do not count as success.
Inspect and listen to recordings before treating their audio as verified.

## Verification

```sh
TZ=Europe/Berlin lua tests/recording_scheduler_test.lua
TZ=Europe/Berlin lua tests/recording_scheduler_host_test.lua
luac -p Tools/JG_Recording_Scheduler.lua
```

The tests use the real parser, state machine, storage, adapter and GUI loop with a
mock REAPER host. They cover timing, migration, dedicated folders, ownership,
file verification, cancelled edits and native picker selection/cancellation/errors.
A real audio test remains necessary before unattended use.

References: [REAPER ReaScript API](https://www.reaper.fm/sdk/reascript/reascripthelp.html)
and [js_ReaScriptAPI dialog definitions](https://github.com/juliansader/ReaExtensions/blob/master/js_ReaScriptAPI/Source%20code/js_ReaScriptAPI_def.h).

Save validation is shown directly under the form buttons. Invalid dates, past starts
or overlaps retain the draft and leave the existing plan unchanged. Saving slots
requires a saved project, but does not require an already prepared audio device.
Recording still requires valid armed audio inputs. A future slot fails visibly if these conditions
are not met at its start.
