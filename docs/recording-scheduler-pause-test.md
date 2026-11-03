# Direct recording pause probe

Status: native pause/resume and Scheduler 2.6.0 integration verified.
The recording mode was withdrawn in 2.6.1: the continuing live item cannot appear
at each slot's clock position until capture ends. Separate slots are now the only
available recording workflow. This document retains the experimental evidence.

Tested on 2026-11-03 with REAPER 7.78+dev0811/macOS-arm64 in an isolated
instance using a temporary configuration. Two stereo output-recording tracks
used a generated 440 Hz JSFX signal with master sends disabled.

## Completed observations

- Transport action 1013 started recording (play state 5).
- After approximately three seconds, action 1008 paused recording (state 6).
- Both WAV files remained at 524288 bytes throughout the three-second pause.
- Action 1008 resumed recording (state 5); the same files grew again.
- After another three seconds and Stop, each track had exactly one WAV and one item.
- Each WAV contained 288768 stereo sample frames at 48000 Hz, 24-bit PCM:
  6.016 seconds, not nine seconds. File size was 1733298 bytes.
- No rendering or file concatenation was used.
- A second test sought to timeline position 10 while paused. Recording still
  appended to the same WAV, but the final item stayed at position 0 with length
  6.016 seconds. Seeking does not automatically create clock-aligned items.

## Source-boundary measurement

A follow-up probe switched the generated signal from 0.1 to 0.2 while paused.
The transition occurred at sample frame 145408 (3.029333333 seconds at 48 kHz),
exactly matching `GetPlayPosition2Ex` at the pause. The audible play cursor was
3.001291667 seconds and must not be used for this boundary. After each resume,
the processing cursor's new base is measured; subsequent deltas are accumulated.

## Integrated Scheduler test

The actual Engine and Host ran three three-second slots with two three-second
gaps, recording two stereo test tracks. Only preflight was replaced to permit
synthetic output recording without microphones. Production preflight continues
to require audio-input recording. Results:

- State sequence: recording, paused, recording, paused, recording, stopped.
- One WAV per track, with all three slots completed.
- In one verified run each WAV contained 430592 frames at 48000 Hz (8.970667 seconds).
- Signal changes occurred at sample frames 143360 and 287232, matching the stored
  source offsets. Three-second scheduling is wall-clock/defer based, not sample exact.
- After stopping, each track had three items at the corresponding clock positions.
  All three referenced the same WAV, with contiguous source offsets and no lost samples.
- Reading and comparing the complete source bytes before and after item placement
  confirmed that the original WAVs were unchanged.
- All six band/track export plans validated successfully against actual audio bounds.
- A repeat with the final recording-input/sample-rate/collision checks again passed:
  431616 frames per WAV, three 143872-frame sections, unchanged original bytes.
- Automated tests additionally cover gap-stop, late/failed resume, external resume,
  persistence, native file splits, and preserving manually edited region edges.

The repeatable probes are in `tests/manual/`. They require an empty disposable
project and the isolated `/tmp/jg-pause-probe` resource directory. The integrated
probe uses a JSFX constant signal with slider1 controlling its level; master sends
are disabled. These short CoreAudio output-recording tests do not establish
long-duration or every-hardware/input-latency reliability. REAPER's configured
file-size limits and splitting preferences still apply.
