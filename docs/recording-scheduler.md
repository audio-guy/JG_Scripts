# Recording Scheduler 2.6.8

## Purpose

For unattended audio recordings and attended live capture, not studio workflows.
Each slot starts/stops into its own folder at its clock-time position, including
while recording. Adjacent slots can have a short stop/start gap. The running
slot's name and end remain editable; its start stays fixed. There is no mode
selector, repetition, pre/post-roll control, template or confirmation checklist.
The recording destination is always the directory containing the saved RPP.

Shared WAV was removed because REAPER appends to the existing live item when
resuming. Correct live timeline placement takes priority over sharing one file.
Historical shared recordings and their band-export maps remain available.

## Installation and use

Load `Tools/JG_Recording_Scheduler.lua` in REAPER's Actions list. Requires ReaImGui
0.10 or newer. No folder-picker extension is required.

1. Save the project and arm the intended audio or MIDI input tracks.
2. The Scheduler uses the folder containing the saved project automatically.
3. In **Schedule**, select **Add slot**, enter a name, start and end, and save.
   For overnight recordings, enter the next end date. Leave the end time blank
   for manual stop; there is no Open end checkbox.
4. Saving schedules the slot automatically. Use Duplicate to add another similar slot.
   The schedule is always watched while the Scheduler is open. There is no Pause
   or Resume step.

Dates use `YYMMDD`; times accept `HH:MM`, `HHMM`, `HH:MM:SS` and `HHMMSS`.
For example, `175930` means `17:59:30`, for both start and end times. Invalid and ambiguous daylight-saving times are rejected.
Overlaps never silently change the plan. When the new start falls inside the
previous scheduled slot (including an open-ended slot), the editor offers to end
that slot at the new start. **Shorten and save** applies both changes together;
**Keep editing** leaves the plan unchanged. Undo restores both changes. Equal
starts, additional conflicts and already recorded slots require manual correction.
If the schedule changes while confirmation is open, it must be reviewed again.
Saving a slot directly adjacent to another planned or running slot requires
**Save anyway** or **Keep editing**. The notice reads: "These slots meet without a
gap. Starting a new recording file will cause a brief interruption." Enter does
not confirm it. Editing a field or changing the plan invalidates confirmation.
The same notice accompanies **Shorten and save** when resolving an overlap.
No confirmation dialog appears at recording time.
Saving a slot requires a saved REAPER project. A rejected draft stays
open so it can be saved after saving the project. Readiness issues are shown before
the first start; the start-time safety check still runs.
Missed slots that never started recording can be edited and saved with a new future
start, including when the original start passes while the editor is open. Slots
that already ran or attempted to record retain their history; use Duplicate instead.

## Timeline placement

A start at 00:52 is placed at timeline time 00:52:00, independent of the edit cursor
or project length. The first recording establishes a midnight reference day, saved
with the project. Later days continue beyond 24 hours rather
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

The directory containing the saved `.RPP` is the parent. Each slot records into
its own `YYMMDD - HHMM Name` subfolder directly beside the project file. No audio is recorded in gaps between slots.

Folder names preserve user names, replacing only filesystem-invalid characters.
REAPER's separate recording/media path and old Scheduler destination overrides
are not used for new recordings. Existing audio and historical capture paths are not moved. Separate-slot directories may be reused;
REAPER supplies unique filenames. Existing shared-session directories remain unchanged.

## MIDI recording

Audio and MIDI inputs are supported, including mixed sessions. Tracks must use
Record: input (audio or MIDI). Output recording, MIDI overdub and MIDI replace
remain excluded to protect existing material. A MIDI recording is verified by
new takes containing notes, CC/program events or text/SysEx events. Existing takes
and empty MIDI takes do not count as successful input capture.

REAPER's MIDI storage preference is retained: embedded MIDI is stored in the RPP,
not as a WAV or necessarily as a file in the slot folder. After a MIDI recording,
the Scheduler saves the already named project, including its other current edits,
after restoring the original recording destination. A save that cannot be confirmed
marks the slot Failed with a request to save the project. Audio-only recording does
not trigger this additional project save. Historical band WAV export is audio-only.

## Historical band regions and export

Earlier Continuous / Shared WAV versions created named regions from the planned times.
The following export workflow remains available for those recordings. These are
editing boundaries, not transport commands. They remain editable after recording;
changing a region does not reschedule a recording. An open-ended final region is
closed when recording stops, including a manual REAPER transport stop while the
Scheduler stays running. During capture it is a short placeholder, not a growing
region. Its final end is limited to the actual captured audio. Generated finite ends are
also fitted to the available samples; manually adjusted edges are preserved.
Editing a running slot updates its linked region
name/end. Changing the final slot’s end also changes the shared capture stop.

1. Finish the recording and adjust the band regions in REAPER. Keep their region
   IDs: move/resize/rename them, rather than deleting/recreating or renumbering them.
2. In Schedule, click **Export band folders...**. Select the bands to export.
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
recording. Upcoming slots continue to be watched; a recording start cancels any
unfinished export. Close the Scheduler to cancel an active export.
The application does not change global REAPER file-splitting preferences. Native
size limits or enabled file splitting may still create multiple source files per
track; pause/resume itself does not create a new file. Configure WAV/RF64 and the
file-size settings in REAPER when one physical WAV per track is required.

## Interface

The window title shows the running version (for example, Recording Scheduler v2.6.8).
Restart the script after updating to load the new version. This identifies the
loaded version; it does not check online for updates.

The transport header is hidden when no recording is active or scheduled.
The UI is designed for an experienced operator. The compact header shows state and
next/active slot; one message area displays concrete issues. There are no navigation
tabs or Recording help panel. Technical checks remain enforced. There is no
admin/guest distinction.


- **Schedule:** next recording/countdown, transport controls and scrollable plan.
  Length / left shows planned duration while waiting and a seconds countdown while
  recording. Open-ended recordings show Manual stop.
  Select a row for Edit, Duplicate or Delete. Double-click an editable slot to open
  its editor; recorded history stays protected. Completed/stopped entries are hidden
  initially; failures remain visible. Show history reveals past entries.
  Delete removes any inactive slot from the plan, including failed and completed
  slots. It never deletes audio files. Undo restores the removed entry.
- **Slot editor:** optional name, dates and times. Add slot focuses the name field immediately. Blank names become Slot N using the slot number. Use Duplicate for similar slots. Save or Enter in any input field returns to the plan after validation; Cancel
  discards the draft. Tab and mouse focus changes retain edits immediately. Both Return
  and keypad Enter submit from an input field. Enter never confirms an overlap adjustment automatically. Existing slots keep running on schedule while you plan another.
- **Activity log:** opens a separate optional window with events and verified file
  paths, newest first. Closing it leaves scheduling active. Export log writes
  `<project>.rpp.recording-log.tsv` and replaces the previous export.

While recording, double-click the currently recording slot or use Edit selected.
Its name and end time can change; its start date/time are locked. Leave the end
blank for manual stop if no later slot would overlap. The new end must be in the
future and must not overlap another slot. The list and recording stop are updated together without restarting transport.
The Extend by 5 min control has been removed.

Add slot stays available during recording. New slots are scheduled with their own
folders; saving does not interrupt the current recording.
A running or planned predecessor can be shortened at the new start only after
explicit confirmation. Conflicts with other slots are rejected before changing the
plan or regions. Adding during capture clears the Undo snapshot.
Deleting, duplicating and undoing plan changes remain locked during capture. Completed recording history cannot be edited.
If a recording ends while its editor is open, saving is rejected. Live edits clear
the plan Undo snapshot to prevent restoring stale recording state.
Stop recording ends the current slot. Future independent slots
remain scheduled. Closing during an active recording asks whether to stop and close or keep running.
Otherwise closing directly disables future starts and retains the plan.

## Readiness and limitations

The automatic check verifies the saved/selected project, absence of another
recording, armed audio- or MIDI-input tracks, open audio device, and disabled looping.
Normal or paused playback is stopped automatically immediately before seeking and
starting the scheduled recording. If stopping fails, no recording command is sent. Destination folders
are created and write-tested at each actual start. Existing manual
recordings are never taken over. Recordings use clock-aligned timeline positions;
collisions with existing media on armed tracks block the start.

There are no mandatory confirmation checkboxes. The operator still needs normal
record mode, no recording-length limit/count-in, automatic retention of recorded
files, correct routing/levels, sufficient disk space and a computer that stays awake.
These conditions are not all measured by the script. Writing a small probe file does not reserve disk space.

The scheduler is bound to its original project. Returning to the target project
resumes watching upcoming slots automatically. Changing project tabs disables
future starts; an owned recording keeps its scheduled stop in the original project.
Window visibility and selected GUI view do not affect scheduling.

Timing uses system wall time and REAPER's deferred loop, not an audio-thread clock.
Blocking dialogs, sleep, crashes and device failures can interrupt automation.
Starts over five seconds late are missed; late stops or clock changes require review.

## Persistence and migration

Plans, capture maps, region links and logs are stored in project extstate and an immediate recovery
sidecar, `<project>.rpp.jg-scheduler`. Save the project normally to embed the extstate;
keep the sidecar with the project. Failed recovery-file writes disable future starts.
Corrupt data is preserved for recovery instead of overwritten. A crash before
finalization can leave compact items in the project. Source boundary maps are
retained in the sidecar for manual recovery; reopening does not resume an open
recording or automatically rearrange interrupted material. Missing/conflicting
items stop automatic placement and block export rather than modifying originals.

Reopening automatically watches future slots. Obsolete saved pause flags are
ignored. Version 2 plans retain separate slots. Existing Continuous / Shared WAV plans now use separate slots; their earlier
recordings and export maps remain unchanged. Format version 4
adds source-boundary maps and reads formats 2 and 3. Past starts become Missed; previously
active slots become Interrupted. Old repeated entries remain as individual slots. Pending legacy slots
with pre/post-roll are converted to visible direct start/end times, preserving the
actual recording window including seconds. Completed history retains its original
times. Duplicating legacy history exposes its effective times in the editor rather
than silently applying hidden margins. Legacy template data remains readable and
is preserved for compatibility, but templates are no longer available in the UI.

## Results

| Status | Meaning |
|---|---|
| Scheduled | Starts automatically at the planned time while the Scheduler is open |
| Recording | The slot is recording |
| Completed | New audio files or new MIDI events verified on every expected track |
| Partial | Files found, but timing was late or the system clock changed |
| Stopped | Recording stopped through manual intervention or script closure |
| Missed | Start more than five seconds late, or entire window elapsed |
| Failed | Start or file verification failed |
| Interrupted | Previous scheduler session ended without a verified result |

Completed does not verify signal quality, full duration, underruns or file integrity.
Pre-existing files and new files outside the slot folder do not count as success.
Inspect and listen to recordings before treating their audio as verified.

## Verification

The native MIDI probe `tests/manual/recording_scheduler_midi_host.lua` was run in
an isolated REAPER 7.78+dev0811/macOS-arm64 instance on 2026-11-03. Two MIDI-input
tracks and two scheduled slots produced four items at their clock positions,
containing notes and CC events. Both slots completed and all four MIDI sources
were found in the saved RPP. Virtual-keyboard input was used; no external MIDI
hardware was required. The normal preflight and recording adapter were used.


```sh
TZ=Europe/Berlin lua tests/recording_scheduler_test.lua
TZ=Europe/Berlin lua tests/recording_scheduler_host_test.lua
TZ=Europe/Berlin lua tests/recording_scheduler_export_test.lua
luac -p Tools/JG_Recording_Scheduler.lua
```

The tests use the real parser, state machine, storage, adapter and GUI loop with a
mock REAPER host. They cover timing, migration, dedicated folders, ownership,
file verification, cancelled edits and project-directory destination placement.
Generated PCM fixtures additionally verify sample-byte-accurate region cuts, split
source files, format handling and cancellation. The native two-track/three-slot test and its limitations are documented in
[the pause test report](recording-scheduler-pause-test.md). Tests with the intended
input hardware remain necessary before unattended use; output-recording probes
cannot validate every driver's latency compensation or disk behavior.

References: [REAPER ReaScript API](https://www.reaper.fm/sdk/reascript/reascripthelp.html)
and [js_ReaScriptAPI dialog definitions](https://github.com/juliansader/ReaExtensions/blob/master/js_ReaScriptAPI/Source%20code/js_ReaScriptAPI_def.h).

Save validation is shown directly under the form buttons. Invalid dates, past starts
or overlaps retain the draft and leave the existing plan unchanged. Saving slots
requires a saved project, but does not require an already prepared audio device.
Recording still requires valid armed audio or MIDI inputs. A future slot fails visibly if these conditions
are not met at its start.

A system-clock jump retains a safety hold: check the clock and reopen the Scheduler.
Removing manual Pause/Resume does not bypass recording or storage safety checks.
