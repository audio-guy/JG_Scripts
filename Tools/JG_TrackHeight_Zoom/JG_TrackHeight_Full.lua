-- JG_TrackHeight_Full.lua
-- Set all tracks to full visible track area height, scroll to selected track

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- Measure arrange height and ruler offset first
local arrange = reaper.JS_Window_FindChildByID(reaper.GetMainHwnd(), 1000)
local _, _, arr_top, _, arr_bottom = reaper.JS_Window_GetClientRect(arrange)
local arrange_h = math.abs(arr_top - arr_bottom)

-- Need to set some height first, scroll to top, measure ruler
local num_tracks = reaper.CountTracks(0)
for i = 0, num_tracks - 1 do
  local track = reaper.GetTrack(0, i)
  reaper.SetMediaTrackInfo_Value(track, "I_HEIGHTOVERRIDE", 100)
end

reaper.TrackList_AdjustWindows(true)

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()

reaper.JS_Window_SetScrollPos(arrange, "SB_VERT", 0)
reaper.UpdateArrange()
local ruler_offset = reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, 0), "I_TCPY")

-- Full track height = arrange height minus ruler
local full_h = math.floor(arrange_h - ruler_offset)
if full_h <= 0 then full_h = 800 end

reaper.PreventUIRefresh(1)

for i = 0, num_tracks - 1 do
  local track = reaper.GetTrack(0, i)
  reaper.SetMediaTrackInfo_Value(track, "I_HEIGHTOVERRIDE", full_h)
end

reaper.TrackList_AdjustWindows(true)

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()

-- Scroll to selected track
local sel_track = reaper.GetSelectedTrack(0, 0)
if sel_track then
  local sel_idx = math.floor(reaper.GetMediaTrackInfo_Value(sel_track, "IP_TRACKNUMBER") - 1)
  reaper.JS_Window_SetScrollPos(arrange, "SB_VERT", sel_idx * full_h)
  reaper.UpdateArrange()
end

reaper.Undo_EndBlock("Set all track heights to full arrange height", -1)
