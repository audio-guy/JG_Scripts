# Recording Scheduler 2.5.1

## Purpose

For unattended audio recordings and attended live capture, not studio workflows.
The main view shows the explicit project recording mode. No repetition,
pre/post-roll controls, templates or confirmation checklist.

- **Continuous recording:** one transport recording from the first future slot to
  the last end, including every gap (even overnight). New projects default to this.
  The schedule is frozen during capture. Bands become editable REAPER regions.
- **Separate slots:** each slot starts/stops into its own folder. Existing version 2
  plans retain this mode. Adjacent slots can have an audio gap.

Mode is never inferred from adjacency. Choose it in Setup before scheduling, or
pause the schedule to change it. Mode/destination cannot change during recording.

## Installation and use

Load `Tools/JG_Recording_Scheduler.lua` in REAPER's Actions list. Requires ReaImGui
0.10 or newer. The optional js_ReaScriptAPI extension supplies the native folder
picker; without it, the destination can still be entered manually.

1. Save the project and arm the intended audio input tracks.
2. In **Setup**, choose the recording mode and destination with **Choose folder...**.
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

## Timeline placement

A start at 00:52 is placed at timeline time 00:52:00, independent of the edit cursor
or project length. The first recording establishes a midnight reference day, saved
with the project and shown in Setup. Later days continue beyond 24 hours rather
than wrapping over existing recordings. Project start-time offsets are respected;
a resulting position before the project start is rejected. Late starts are placed
at their actual start time rather than backdated to the intended start.

The recording span is checked against existing media on armed tracks before any
recording settings or transport changes. A collision blocks the start with an error;
existing material is never automatically moved or overwritten. Existing recordings
and region/export maps from earlier versions stay where they are.

Timeline time is elapsed time from the reference midnight. A daylight-saving clock
change cannot be mirrored during continuous audio without a timeline discontinuity;
after such a change, elapsed timeline time can differ from local clock time.

## Recording destination

The selected folder is the parent. In Separate slots mode each recording has its
own `YYMMDD - HHMM Name` subfolder. In Continuous recording mode the entire session
uses `YYMMDD - HHMM Originals <unique ID>`. This includes audio between bands.

Folder names preserve user names, replacing only filesystem-invalid characters.
The root may be absolute or relative to the saved project. Cancelling the folder
picker preserves the previous path. Separate-slot directories may be reused;
REAPER supplies unique filenames. Continuous sessions use unique directories.

## Band regions and export

Continuous recording creates named regions from the planned times. These are
editing boundaries, not transport commands. They remain editable after recording;
changing a region does not reschedule a recording. An open-ended final region is
closed when recording stops. Extending capture adds recording time, not region
length: adjust the last region afterward if needed.

1. Finish the recording and adjust the band regions in REAPER. Keep their region
   IDs: move/resize/rename them, rather than deleting/recreating or renumbering them.
2. In Schedule, click **Export band folders...**. Pause future scheduling first.
3. Select the bands to export. Missing or unrecorded regions can be deselected.
4. Click **Export now**. Current region boundaries/names are read again at confirmation.

Each export creates a unique `Band exports YYMMDD - HHMMSS <ID>` directory under
the destination, with `YYMMDD - HHMM Name` band subfolders and one WAV per captured
track. The folder timestamp follows the adjusted region start mapped to the
capture's original wall-clock start. Original files are never moved, split or
modified. Existing exports are not overwritten. Cancellation keeps finished files
and removes the current partial file.

Export copies original PCM/float sample bytes from WAV/RF64 sources, including
multiple contiguous source files per track. It preserves sample rate, channels and
sample format, bypassing project/track/take FX, gain, normalization and subsequent
item edits. It uses the captured original timeline/source mapping, not a mix render.
WAV metadata chunks such as BWF/iXML are not copied. Other formats (FLAC, WavPack,
MP3, W64, etc.) are rejected. Regions outside available audio, source gaps, mixed
sample rates and unverified recordings are rejected rather than padded silently.
Output automatically uses RF64 when it exceeds RIFF size limits.

The recording must finish through this Scheduler to collect its source map.
After a crash or interrupted recovery, inspect/export the recovered recording
manually in REAPER. Files under the project directory are stored as relative paths
so moving that entire directory preserves export access. Externally stored sources
must remain accessible at their original locations. Band capture records remain
available after deleting schedule rows; deleting rows never deletes audio/regions.

Export runs in small deferred chunks, may be cancelled and is unavailable during
recording or active scheduling. Close the Scheduler to cancel an active export.
The application does not change global REAPER file-splitting preferences: continuous
capture may comprise several physically separate WAV files.

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
active recording. Pause scheduling before changing the destination folder. The active end can be extended by five minutes. In Separate slots mode this must
not conflict with a later slot. Continuous mode extends the entire capture. Undo restores the last plan change.
Pause schedule leaves an active recording's scheduled stop intact. In Continuous
mode that means the last slot's end, including all remaining bands and pauses. Stop recording
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

Plans, capture maps, region links and logs are stored in project extstate and an immediate recovery
sidecar, `<project>.rpp.jg-scheduler`. Save the project normally to embed the extstate;
keep the sidecar with the project. Failed recovery-file writes disable future starts.
Corrupt data is preserved for recovery instead of overwritten.

Reopening automatically watches future slots unless you explicitly paused the plan.
An explicit pause and the selected mode are retained across reopening. Version 2
plans are migrated to Separate slots; version 3 persists the explicit mode. Past starts become Missed; previously
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
TZ=Europe/Berlin lua tests/recording_scheduler_export_test.lua
luac -p Tools/JG_Recording_Scheduler.lua
```

The tests use the real parser, state machine, storage, adapter and GUI loop with a
mock REAPER host. They cover timing, migration, dedicated folders, ownership,
file verification, cancelled edits and native picker selection/cancellation/errors.
Generated PCM fixtures additionally verify sample-byte-accurate region cuts, split
source files, format handling and cancellation. A real audio test remains necessary
before unattended use; mocked host tests cannot validate driver or disk timing.

References: [REAPER ReaScript API](https://www.reaper.fm/sdk/reascript/reascripthelp.html)
and [js_ReaScriptAPI dialog definitions](https://github.com/juliansader/ReaExtensions/blob/master/js_ReaScriptAPI/Source%20code/js_ReaScriptAPI_def.h).

Save validation is shown directly under the form buttons. Invalid dates, past starts
or overlaps retain the draft and leave the existing plan unchanged. Saving slots
requires a saved project, but does not require an already prepared audio device.
Recording still requires valid armed audio inputs. A future slot fails visibly if these conditions
are not met at its start.
