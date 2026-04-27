-- @description Go to previous item edge (track selection aware)
-- @author Julius Gass
-- @about
--   Moves the edit cursor to the previous item edge on the selected tracks
--   (or all tracks if none are selected). The view stays centered on the
--   cursor and the view width is preserved.
--
--   Edge logic:
--     * Always prefer the item that STARTS at the edge position
--       (back-to-back items: item B is selected because B starts there).
--     * Only if no item starts at the edge (pure end edge with gap following),
--       the item ending there is selected.

local EPS = 1e-9

local function collect_items()
  local items = {}
  local sel_track_count = reaper.CountSelectedTracks(0)
  if sel_track_count > 0 then
    for i = 0, sel_track_count - 1 do
      local tr = reaper.GetSelectedTrack(0, i)
      local item_count = reaper.CountTrackMediaItems(tr)
      for j = 0, item_count - 1 do
        local it = reaper.GetTrackMediaItem(tr, j)
        local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
        items[#items + 1] = { item = it, s = pos, e = pos + len }
      end
    end
  else
    local item_count = reaper.CountMediaItems(0)
    for i = 0, item_count - 1 do
      local it = reaper.GetMediaItem(0, i)
      local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
      items[#items + 1] = { item = it, s = pos, e = pos + len }
    end
  end
  return items
end

local function build_edges(items)
  local map = {}
  for _, it in ipairs(items) do
    local sk = string.format("%.9f", it.s)
    local ek = string.format("%.9f", it.e)
    if not map[sk] then map[sk] = { pos = it.s, starts = {}, ends = {} } end
    map[sk].starts[#map[sk].starts + 1] = it
    if not map[ek] then map[ek] = { pos = it.e, starts = {}, ends = {} } end
    map[ek].ends[#map[ek].ends + 1] = it
  end
  local edges = {}
  for _, e in pairs(map) do edges[#edges + 1] = e end
  table.sort(edges, function(a, b) return a.pos < b.pos end)
  return edges
end

reaper.PreventUIRefresh(1)

local items = collect_items()
if #items == 0 then
  reaper.PreventUIRefresh(-1)
  return
end

local edges = build_edges(items)
local cursor = reaper.GetCursorPosition()

local target
for i = #edges, 1, -1 do
  local e = edges[i]
  if e.pos < cursor - EPS then
    target = e
    break
  end
end

if not target then
  reaper.PreventUIRefresh(-1)
  return
end

local sel_item
if #target.starts > 0 then
  sel_item = target.starts[1].item
elseif #target.ends > 0 then
  sel_item = target.ends[1].item
end

reaper.SetEditCurPos(target.pos, false, false)

reaper.Main_OnCommand(40289, 0) -- Item: Unselect all items
if sel_item then
  reaper.SetMediaItemSelected(sel_item, true)
end

local start_time, end_time = reaper.GetSet_ArrangeView2(0, false, 0, 0)
local wide = end_time - start_time
reaper.GetSet_ArrangeView2(0, true, 0, 0, target.pos - wide / 2, target.pos + wide / 2)

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
