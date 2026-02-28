-- @description Copy timecode to clipboard
-- @author JG
-- @version 1.0.0
-- @about
--   Copies the playhead (playback) or edit cursor (stopped) timecode to the clipboard.
--   Requires the SWS Extension.

local state = reaper.GetPlayState() -- 1=play, 2=pause, 4=record

local pos
if state == 0 then
  pos = reaper.GetCursorPosition()
else
  pos = reaper.GetPlayPosition()
end

local tc = reaper.format_timestr_pos(pos, "", -1)

reaper.CF_SetClipboard(tc)