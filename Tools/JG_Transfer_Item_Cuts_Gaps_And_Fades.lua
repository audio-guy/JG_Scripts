-- @description Transfer cuts, gaps and fades to other tracks
-- @author JG
-- @version 1.0.0
-- @about
--   Matches the cuts and gaps of a reference track to other selected tracks.
--   The track with the most selected items is automatically used as the reference.
--   Also copies fade-in and fade-out parameters to the target items.

local track_data = {}

for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
  local item  = reaper.GetSelectedMediaItem(0, i)
  local track = reaper.GetMediaItem_Track(item)
  local tid   = reaper.GetTrackGUID(track)
  if not track_data[tid] then
    track_data[tid] = { track = track, items = {} }
  end
  table.insert(track_data[tid].items, {
    item = item,
    pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
    len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  })
end

local track_list = {}
for _, v in pairs(track_data) do
  table.sort(v.items, function(a, b) return a.pos < b.pos end)
  table.insert(track_list, v)
end

if #track_list < 2 then
  reaper.ShowMessageBox("Select items on at least 2 tracks", "Error", 0)
  return
end

table.sort(track_list, function(a, b) return #a.items > #b.items end)

local src     = track_list[1]
local targets = {}
for i = 2, #track_list do
  table.insert(targets, track_list[i])
end

local keep_intervals = {}
for _, it in ipairs(src.items) do
  table.insert(keep_intervals, { s = it.pos, e = it.pos + it.len })
end

local range_start = keep_intervals[1].s
local range_end   = keep_intervals[#keep_intervals].e

local split_points = {}
local seen = {}
for _, iv in ipairs(keep_intervals) do
  if not seen[iv.s] then
    table.insert(split_points, iv.s)
    seen[iv.s] = true
  end
  if not seen[iv.e] then
    table.insert(split_points, iv.e)
    seen[iv.e] = true
  end
end
table.sort(split_points)

local function in_keep(pos)
  for _, iv in ipairs(keep_intervals) do
    if pos >= iv.s - 0.0001 and pos < iv.e - 0.0001 then
      return true
    end
  end
  return false
end

local function get_track_items(track)
  local items = {}
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    table.insert(items, { item = item, pos = pos, len = len })
  end
  table.sort(items, function(a, b) return a.pos < b.pos end)
  return items
end

local fade_params = {
  "D_FADEINLEN", "D_FADEOUTLEN",
  "D_FADEINTYPE", "D_FADEOUTTYPE",
  "D_FADEINDIR", "D_FADEOUTDIR"
}

reaper.Undo_BeginBlock()

for _, tgt in ipairs(targets) do
  -- 1. Splitten
  for _, sp in ipairs(split_points) do
    local current = get_track_items(tgt.track)
    for _, ti in ipairs(current) do
      if sp > ti.pos + 0.0001 and sp < ti.pos + ti.len - 0.0001 then
        reaper.SplitMediaItem(ti.item, sp)
        break
      end
    end
  end

  -- 2. Löschen: Pausen + außerhalb Referenzbereich
  local final_items = get_track_items(tgt.track)
  local to_delete = {}
  for _, ti in ipairs(final_items) do
    local item_mid = ti.pos + ti.len / 2
    if item_mid < range_start or item_mid >= range_end or not in_keep(ti.pos) then
      table.insert(to_delete, ti.item)
    end
  end
  for _, item in ipairs(to_delete) do
    reaper.DeleteTrackMediaItem(tgt.track, item)
  end

  -- 3. Fades übertragen
  local remaining = get_track_items(tgt.track)
  for _, ti in ipairs(remaining) do
    for _, si in ipairs(src.items) do
      if math.abs(ti.pos - si.pos) < 0.0001 then
        for _, param in ipairs(fade_params) do
          reaper.SetMediaItemInfo_Value(ti.item, param,
            reaper.GetMediaItemInfo_Value(si.item, param))
        end
        break
      end
    end
  end
end

reaper.Undo_EndBlock("Transfer cuts, gaps and fades", -1)
reaper.UpdateArrange()