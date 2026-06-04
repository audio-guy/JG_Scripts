-- @description Label score measures (printed measure numbers as locked items)
-- @author JG
-- @version 1.3.0
-- @about
--   Creates one empty, beat-locked item per measure on a dedicated, pinned
--   track ("Score Measures"), labelled with the *printed* score measure number.
--   Between two anchors the number counts +1 per measure; an anchor restarts
--   the numbering. Anchor markers are tinted (default red) so you can see at a
--   glance where the numbering restarts (e.g. at repeats).
--
--   SET AN ANCHOR = add a normal project marker named "=NN", e.g.:
--       =789   -> the measure containing this marker is printed measure 789,
--                 then +1 per measure until the next anchor.
--   Any number of anchors is allowed. Place the marker on the measure downbeat
--   (slightly off-grid markers are rounded to the nearest measure start).
--   Without any anchor the printed number follows REAPER's displayed bar
--   numbers, so the project "start measure offset" setting is respected.
--
--   The label items use the "beats (position + length)" timebase so they follow
--   tempo-map edits, their text is stretched to fill the item, and the track is
--   pinned to the top, height-locked, coloured and its items are locked.
--
--   Workflow: set markers -> run. Change something -> adjust markers -> run
--   again (old labels are replaced automatically).

-- ── Config ───────────────────────────────────────────────────────────────
local LABEL_TRACK_NAME   = "Score Measures"
local ANCHOR_PATTERN     = "^%s*=%s*(%d+)"   -- marker name like  =789
local LOCK_ITEMS         = true              -- lock label items against editing
local PIN_TO_TOP         = true              -- move track to the very top on each run
local LOCK_HEIGHT        = true              -- fixed, locked track height
local LABEL_TRACK_HEIGHT = 60                -- px (only used when LOCK_HEIGHT)
local STRETCH_TEXT       = true              -- stretch label text to fill the item
local COLOR_LABELS       = true              -- colour track + items
local LABEL_COLOR        = { 255, 255, 255 } -- RGB. White keeps the dark default item
                                             -- text readable. Use { 0, 0, 0 } only if
                                             -- your theme auto-contrasts to white text.
local COLOR_ANCHORS      = true              -- tint =NN markers so renumbering points stand out
local ANCHOR_COLOR       = { 255, 60, 60 }   -- RGB for the =NN anchor markers
local proj = 0

local function nativeColor(rgb)
  return reaper.ColorToNative(rgb[1], rgb[2], rgb[3]) | 0x1000000
end

-- ── 1) Collect anchors from markers ──────────────────────────────────────
-- Returns the measure index (0-based) a time position falls in, rounded to the
-- nearest measure start so slightly-off markers still land on the right downbeat.
local function measureIndexAt(pos)
  local _, measures = reaper.TimeMap2_timeToBeats(proj, pos)
  local mi     = math.floor(measures + 1e-9)
  local tStart = reaper.TimeMap2_beatsToTime(proj, 0.0, mi)
  local tNext  = reaper.TimeMap2_beatsToTime(proj, 0.0, mi + 1)
  if pos > (tStart + tNext) * 0.5 then mi = mi + 1 end
  return mi
end

-- Bar number REAPER *displays* at the downbeat of measure index m. Uses the same
-- formatter as the ruler/transport, which honours the project "start measure
-- offset" setting (there is no direct API getter for that offset).
local function displayedBar(m)
  local t = reaper.TimeMap2_beatsToTime(proj, 0.0, m) + 1e-6
  local s = reaper.format_timestr_pos(t, "", 2)   -- "<bar>.<beat>.<frac>"
  local bar = s:match("^%s*(-?%d+)")
  return tonumber(bar) or (m + 1)
end

local anchors = {}
local i = 0
while true do
  local retval, isrgn, pos, rgnend, name, markidx = reaper.EnumProjectMarkers3(proj, i)
  if retval == 0 then break end
  if not isrgn then
    local num = name:match(ANCHOR_PATTERN)
    if num then
      anchors[#anchors + 1] = {
        mi = measureIndexAt(pos), printed = tonumber(num),
        markidx = markidx, pos = pos, rgnend = rgnend, name = name,
      }
    end
  end
  i = i + 1
end

-- Base anchor: timeline measure 1 (index 0) = printed measure 1, unless overridden
local hasZero = false
for _, a in ipairs(anchors) do if a.mi == 0 then hasZero = true end end
if not hasZero then anchors[#anchors + 1] = { mi = 0, printed = displayedBar(0) } end
table.sort(anchors, function(a, b) return a.mi < b.mi end)

local function printedFor(m)
  local best = anchors[1]
  for _, a in ipairs(anchors) do
    if a.mi <= m then best = a else break end
  end
  return best.printed + (m - best.mi)
end

-- ── 2) Find or create the label track ────────────────────────────────────
local function findOrCreateTrack(nm)
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    local _, cur = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if cur == nm then return tr end
  end
  reaper.InsertTrackAtIndex(0, true)
  local tr = reaper.GetTrack(proj, 0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", nm, true)
  return tr
end

-- Pin the track to the top (REAPER has no per-track lock; we move it on each run,
-- lock its height and lock its items instead).
local function pinToTop(tr)
  local sel = {}
  for t = 0, reaper.CountSelectedTracks(proj) - 1 do
    sel[#sel + 1] = reaper.GetSelectedTrack(proj, t)
  end
  reaper.SetOnlyTrackSelected(tr)
  reaper.ReorderSelectedTracks(0, 0)        -- move before track index 0
  for t = 0, reaper.CountTracks(proj) - 1 do
    reaper.SetTrackSelected(reaper.GetTrack(proj, t), false)
  end
  for _, t in ipairs(sel) do reaper.SetTrackSelected(t, true) end
end

-- Stretch an empty item's text to fill the item (IMGRESOURCEFLAGS bit "3").
local function stretchItemText(item)
  local ok, chunk = reaper.GetItemStateChunk(item, "", false)
  if not ok then return end
  if chunk:find("IMGRESOURCEFLAGS") then
    chunk = chunk:gsub("IMGRESOURCEFLAGS%s+%-?%d+", "IMGRESOURCEFLAGS 3", 1)
  else
    chunk = chunk:gsub("(>)%s*$", "IMGRESOURCEFLAGS 3\n%1", 1)
  end
  reaper.SetItemStateChunk(item, chunk, false)
end

-- ── 3) Generate ──────────────────────────────────────────────────────────
reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local track   = findOrCreateTrack(LABEL_TRACK_NAME)
local projLen = reaper.GetProjectLength(proj)
local color   = COLOR_LABELS and nativeColor(LABEL_COLOR) or nil

-- tint anchor markers so renumbering / repeat points are visible
if COLOR_ANCHORS then
  local ac = nativeColor(ANCHOR_COLOR)
  for _, a in ipairs(anchors) do
    if a.markidx then
      reaper.SetProjectMarker3(proj, a.markidx, false, a.pos, a.rgnend, a.name, ac)
    end
  end
end

-- remove old labels
for it = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
  reaper.DeleteTrackMediaItem(track, reaper.GetTrackMediaItem(track, it))
end

-- one empty item per measure, notes = printed measure number
local m = 0
while true do
  local startT = reaper.TimeMap2_beatsToTime(proj, 0.0, m)
  if startT > projLen then break end
  local endT = reaper.TimeMap2_beatsToTime(proj, 0.0, m + 1)

  local item = reaper.AddMediaItemToTrack(track)            -- empty item (no take)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", startT)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", endT - startT)
  reaper.GetSetMediaItemInfo_String(item, "P_NOTES", tostring(printedFor(m)), true)
  reaper.SetMediaItemInfo_Value(item, "C_BEATATTACHMODE", 1) -- beats: position + length
  if color then reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", color) end
  if LOCK_ITEMS then reaper.SetMediaItemInfo_Value(item, "C_LOCK", 1) end
  if STRETCH_TEXT then stretchItemText(item) end

  m = m + 1
  if m > 100000 then break end                             -- safety net
end

-- pin / height-lock / colour the track
if PIN_TO_TOP then pinToTop(track) end
if LOCK_HEIGHT then
  reaper.SetMediaTrackInfo_Value(track, "I_HEIGHTOVERRIDE", LABEL_TRACK_HEIGHT)
  reaper.SetMediaTrackInfo_Value(track, "B_HEIGHTLOCK", 1)
end
if color then reaper.SetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR", color) end

reaper.TrackList_AdjustWindows(false)
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Label score measures", -1)
