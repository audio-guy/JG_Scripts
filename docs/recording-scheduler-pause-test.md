# Direct recording pause probe

Status: native pause/resume confirmed; Scheduler integration pending.

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

## Remaining integration requirement

Measure the precise recorded-source boundary at each pause before implementing
item splitting and clock-time placement. The reported audible play position was
slightly behind the final recorded duration. Do not use wall-clock duration alone
as a sample boundary. Test process position and available live item lengths in
an initialized, running audio engine.

The follow-up measurement was interrupted by the Mac becoming locked. Production
Scheduler behavior has not yet been changed. The disposable probe script is
`tests/manual/recording_scheduler_pause_probe.lua`; it refuses to run outside its
isolated resource directory or in a project containing tracks.
