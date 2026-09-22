-- Run from the repository root: lua tests/copy_item_properties_test.lua [script]
local path = arg[1] or "Tools/JG_Copy_Item_Properties.lua"
local f = assert(io.open(path))
local source = f:read("*a")
f:close()
-- Load the real operation without starting the ReaImGui event loop.
source = assert(source:match("^(.-)\nloadPrefs%(%)"))
local r, selected = {}, {}
reaper = r
r.ImGui_CreateContext = function() end
r.CountSelectedMediaItems = function() return #selected end
r.GetSelectedMediaItem = function(_, i) return selected[i + 1] end
r.GetMediaItem_Track = function(it) return it.track end
r.GetTrackGUID = function(t) return tostring(t.num) end
r.GetTrackName = function(t) return true, "Track " .. t.num end
r.GetMediaTrackInfo_Value = function(t) return t.num end
r.GetMediaItemInfo_Value = function(it, key) return it[key] or 0 end
r.SetMediaItemInfo_Value = function(it, key, value) it[key] = value end
r.GetActiveTake = function() return nil end
r.CountTrackMediaItems = function(t) return #t.items end
r.GetTrackMediaItem = function(t, i) return t.items[i + 1] end
r.SplitMediaItem = function(it, pos)
  local right = {}
  for k, v in pairs(it) do right[k] = v end
  right.D_POSITION = pos
  right.D_LENGTH = it.D_POSITION + it.D_LENGTH - pos
  it.D_LENGTH = pos - it.D_POSITION
  table.insert(it.track.items, right)
  return right
end
r.DeleteTrackMediaItem = function(t, it)
  for i, v in ipairs(t.items) do
    if v == it then table.remove(t.items, i); it.deleted = true; return end
  end
  error("Deleting unknown item")
end
for _, name in ipairs({"PreventUIRefresh", "Undo_BeginBlock", "Undo_EndBlock", "UpdateArrange"}) do
  r[name] = function() end
end
local run, opt, collect = assert(load(source .. "\nreturn run, opt, collectSelection", path))()
local function item(t, pos, len, select, gain)
  local it = {track = t, D_POSITION = pos, D_LENGTH = len, D_VOL = gain or 1}
  table.insert(t.items, it)
  if select then table.insert(selected, it) end
  return it
end
local function scenario(cuts, outside)
  selected = {}
  for k in pairs(opt) do opt[k] = nil end
  opt.cuts, opt.outside, opt.itemvol = cuts, outside, true
  local ref, dst = {num = 1, items = {}}, {num = 2, items = {}}
  item(ref, 0, 10, true, 0.5)
  local target = item(dst, 0, 4, true)
  local neighbor = item(dst, 8, 6, false)
  local distant = item(dst, 20, 2, false)
  run(collect(), 1)
  assert(neighbor.D_LENGTH == 6 and not neighbor.deleted,
    "Unselected neighbor shortened: expected length 6, got " .. neighbor.D_LENGTH)
  assert(neighbor.D_VOL == 1, "Unselected neighbor properties changed")
  assert(not distant.deleted, "Unselected distant item deleted")
  assert(target.D_LENGTH == 4 and target.D_VOL == 0.5, "Selected target not copied correctly")
end
scenario(true, true)
scenario(true, false)
scenario(false, false)
print("PASS: longer reference leaves unselected neighbors unchanged (cuts on/off, outside on/off)")

for _, outside in ipairs({true, false}) do
  selected = {}
  opt.cuts, opt.outside = true, outside
  local ref, dst = {num = 1, items = {}}, {num = 2, items = {}}
  item(ref, 2, 2, true, 0.5)
  item(ref, 6, 2, true, 0.25)
  local target = item(dst, 0, 10, true)
  local neighbor = item(dst, 3, 6, false)
  run(collect(), 1)
  assert(neighbor.D_LENGTH == 6 and neighbor.D_VOL == 1 and not neighbor.deleted)
  local actual = {}
  for _, it in ipairs(dst.items) do
    if it ~= neighbor then
      actual[#actual+1] = it
    end
  end
  table.sort(actual, function(a, b) return a.D_POSITION < b.D_POSITION end)
  local expected = outside and {{2, 2, 0.5}, {6, 2, 0.25}}
    or {{0, 2, 1}, {2, 2, 0.5}, {6, 2, 0.25}, {8, 2, 1}}
  assert(#actual == #expected, "Wrong number of surviving selected pieces")
  for i, values in ipairs(expected) do
    local it = actual[i]
    assert(it.D_POSITION == values[1] and it.D_LENGTH == values[2]
      and it.D_VOL == values[3], "Incorrect split piece or reference properties")
  end
end
print("PASS: selected targets split at multiple reference edges; gaps/outside handled correctly")
