-- JG_TrackHeight_58.lua
-- Set all tracks to 58px height, center selected track vertically

local height = 58

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local num_tracks = reaper.CountTracks(0)
for i = 0, num_tracks - 1 do
  local track = reaper.GetTrack(0, i)
  reaper.SetMediaTrackInfo_Value(track, "I_HEIGHTOVERRIDE", height)
end

reaper.TrackList_AdjustWindows(true)

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()

local arrange = reaper.JS_Window_FindChildByID(reaper.GetMainHwnd(), 1000)
local _, _, arr_top, _, arr_bottom = reaper.JS_Window_GetClientRect(arrange)
local arrange_h = math.abs(arr_top - arr_bottom)

reaper.JS_Window_SetScrollPos(arrange, "SB_VERT", 0)
reaper.UpdateArrange()
local ruler_offset = reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, 0), "I_TCPY")
local visible_h = arrange_h - ruler_offset

local sel_track = reaper.GetSelectedTrack(0, 0)
if sel_track and visible_h > 0 then
  local sel_idx = math.floor(reaper.GetMediaTrackInfo_Value(sel_track, "IP_TRACKNUMBER") - 1)
  local target = sel_idx * height - (visible_h / 2) + (height / 2)
  if target < 0 then target = 0 end
  reaper.JS_Window_SetScrollPos(arrange, "SB_VERT", math.floor(target))
  reaper.UpdateArrange()
end

reaper.Undo_EndBlock("Set all track heights to 58px", -1)
