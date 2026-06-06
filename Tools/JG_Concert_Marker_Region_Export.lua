-- @description Concert Marker/Region Export (PDF)
-- @author JG
-- @version 1.1.2
-- @about
--   Exports the project's markers and regions as a printable PDF setlist.
--   Each row shows the time-stamp, length (songs only) and the marker/region
--   name. Songs are rendered in bold so they pop visually next to applause /
--   moderation / announcement markers.
--
--   "Songs" are detected by any combination of four strategies (configurable):
--     1. Lane (= marker/region colour group) marked as "Song-Lane"
--     2. All regions count as songs ("Regionen = Songs" toggle)
--     3. Name starts with a configurable prefix trigger (e.g. "*")
--     4. NOT on the blacklist (acts as veto — kills false positives like
--        "Beifall, Applaus, Moderation, Ansage, …")
--
--   Time base toggle: H:MM:SS (default) or bar.beat (respects the project's
--   measure start offset).
--
--   Length is shown for songs only:
--     - Region song: end - start
--     - Marker song: until next song marker (or end of project)
--
--   PDF is written next to the .rpp file and opened in the OS's default
--   reader. No external dependencies — the PDF is built in-script using the
--   PDF standard fonts (Helvetica / Helvetica-Bold).
--
--   Requires ReaImGui (ReaPack: Extensions > ReaPack > Browse packages).

local r = reaper

if not r.ImGui_CreateContext then
  r.MB("This script requires ReaImGui.\n\nInstall it via ReaPack:\nExtensions > ReaPack > Browse packages > search \"ReaImGui\".",
       "Missing dependency", 0)
  return
end

-- ════════════════════════════════════════════════════════════════════════
--  Config / state
-- ════════════════════════════════════════════════════════════════════════
local EXT = "JG_ConcertExport"

local prefs = {
  timeMode     = "time",  -- "time" (H:MM:SS) or "bar" (bar.beat)
  regionAsSong = true,
  prefix       = "",
  blacklist    = "Beifall, Applaus, Moderation, Ansage, Pause, Intro, Outro, Soundcheck",
}

local proj = {
  laneInclude = {},   -- [laneKey] = bool (default true)
  laneSong    = {},   -- [laneKey] = bool (default false)
  override    = {},   -- [markerGuid] = "s" force-song / "n" force-not-song
}

local state = { status = "Configure lanes, then Export." }
local prefsDirty, projDirty = false, false

-- ════════════════════════════════════════════════════════════════════════
--  Persistence
-- ════════════════════════════════════════════════════════════════════════
local function loadPrefs()
  local v
  v = r.GetExtState(EXT, "timeMode")     ; if v ~= "" then prefs.timeMode = v end
  v = r.GetExtState(EXT, "regionAsSong") ; if v ~= "" then prefs.regionAsSong = (v == "1") end
  v = r.GetExtState(EXT, "prefix")       ; if v ~= "" then prefs.prefix = v end
  v = r.GetExtState(EXT, "blacklist")    ; if v ~= "" then prefs.blacklist = v end
end

local function savePrefs()
  r.SetExtState(EXT, "timeMode",     prefs.timeMode, true)
  r.SetExtState(EXT, "regionAsSong", prefs.regionAsSong and "1" or "0", true)
  r.SetExtState(EXT, "prefix",       prefs.prefix, true)
  r.SetExtState(EXT, "blacklist",    prefs.blacklist, true)
end

local function deserMap(s)
  local t = {}
  for kv in (s or ""):gmatch("[^,]+") do
    local k, v = kv:match("^(.-)=(.+)$")
    if k then t[k] = (v == "1") end
  end
  return t
end

local function serMap(t)
  local parts = {}
  for k, v in pairs(t) do
    parts[#parts+1] = k .. "=" .. (v and "1" or "0")
  end
  return table.concat(parts, ",")
end

-- Overrides are stored as "guid=s,guid=n,...". GUIDs contain "{}-" but
-- never "=" or ",", so naive split works.
local function deserOverride(s)
  local t = {}
  for kv in (s or ""):gmatch("[^,]+") do
    local k, v = kv:match("^(.-)=(.+)$")
    if k and v then t[k] = v end
  end
  return t
end

local function serOverride(t)
  local parts = {}
  for k, v in pairs(t) do parts[#parts+1] = k .. "=" .. v end
  return table.concat(parts, ",")
end

local function loadProj()
  local _, inc = r.GetProjExtState(0, EXT, "laneInc")
  local _, sng = r.GetProjExtState(0, EXT, "laneSng")
  local _, ovr = r.GetProjExtState(0, EXT, "override")
  proj.laneInclude = deserMap(inc)
  proj.laneSong    = deserMap(sng)
  proj.override    = deserOverride(ovr)
end

local function saveProj()
  r.SetProjExtState(0, EXT, "laneInc",  serMap(proj.laneInclude))
  r.SetProjExtState(0, EXT, "laneSng",  serMap(proj.laneSong))
  r.SetProjExtState(0, EXT, "override", serOverride(proj.override))
end

-- ════════════════════════════════════════════════════════════════════════
--  Project chunk parsing — try to extract real Reaper 7+ marker lanes.
--  Reaper exposes no API for marker lanes, so we parse the project chunk
--  heuristically. We try several known token names and field positions; if
--  none match, callers fall back to grouping by colour.
-- ════════════════════════════════════════════════════════════════════════
-- Get the raw project chunk. Native Reaper does NOT expose a function for
-- this — GetProjectStateChunk only exists with SWS installed — so we fall
-- back to reading the .rpp file directly (works for any saved project).
local function getProjectChunk()
  if r.GetProjectStateChunk then
    local ok, chunk = r.GetProjectStateChunk(0, false)
    if ok and chunk and chunk ~= "" then return chunk end
  end
  local _, path = r.EnumProjects(-1, "")
  if path and path ~= "" then
    local f = io.open(path, "rb")
    if f then
      local data = f:read("*a")
      f:close()
      return data or ""
    end
  end
  return ""
end

local function getProjectChunkMarkerSection()
  local chunk = getProjectChunk()
  if chunk == "" then return "" end
  local lines = {}
  for line in chunk:gmatch("[^\r\n]+") do
    local t = line:match("^%s*(.-)%s*$")
    if t:match("^MARKER")
       or t:match("^LANE")
       or t:match("LANE")
       or t:match("^RULER")
       or t:match("^<MARK") then
      lines[#lines+1] = t
    end
  end
  return table.concat(lines, "\n")
end

-- Parse marker chunk lines. Reaper 7+ writes ruler lane definitions like:
--   RULERLANE 1 4 Region 0 1 0
--   RULERLANE 2 8 Marker 0 1 0
--   RULERLANE 3 0 Songs 17668058 -1 0
-- Lane names are NOT quoted when they fit a single word; quoted when they
-- contain spaces. The fourth field is the lane name.
--
-- MARKER lines carry the lane index as the LAST integer on the line:
--   MARKER 4 316.29… "Melane Mosaic Choir: …" 8 18390768 1 B {GUID} 0 3
-- where flag bit &1 (4th field) means "is region" — markers and regions share
-- the same MARKER token but have separate idx counters.
-- Returns:
--   laneNames     [laneIdx] = "Lane Name"
--   markerLaneOf  ["m:"|"r:" .. idx] = laneIdx
--   markerGuidOf  ["m:"|"r:" .. idx] = "{GUID}"
local function parseLaneInfo()
  local raw = getProjectChunkMarkerSection()
  if raw == "" then return {}, {}, {} end

  local laneNames    = {}
  local markerLaneOf = {}
  local markerGuidOf = {}

  -- Read one token from a string (quoted "…" or bare \S+), returning
  -- (token, remainder).
  local function readToken(s)
    s = s:match("^%s*(.*)$") or s
    if s:sub(1, 1) == '"' then
      local t, rest = s:match('^"([^"]*)"%s*(.*)$')
      return t, rest or ""
    end
    local t, rest = s:match("^(%S+)%s*(.*)$")
    return t, rest or ""
  end

  for line in raw:gmatch("[^\n]+") do
    -- RULERLANE <idx> <flag> <name> <color> <…>
    local laneIdxStr, after = line:match("^RULERLANE%s+(%-?%d+)%s+(.+)$")
    if laneIdxStr and after then
      local _flag, rest = readToken(after)        -- skip the flag/type field
      local name        = readToken(rest)
      if name and name ~= "" then
        laneNames[tonumber(laneIdxStr)] = name
      end
    end

    -- MARKER <idx> <pos> <name> <flags> <color> 1 B {GUID} <…> <laneIdx>
    local mIdxStr = line:match("^MARKER%s+(%-?%d+)%s")
    if mIdxStr then
      local guidEnd = line:find("}", 1, true)
      if guidEnd then
        local tail = line:sub(guidEnd + 1)
        local last
        for n in tail:gmatch("(%-?%d+)") do last = tonumber(n) end
        if last then
          -- Determine isRegion from the flags field (bit 1).
          local isRegion = false
          local afterMarker = line:match("^MARKER%s+%-?%d+%s+[%-%d%.]+%s+(.+)$")
          if afterMarker then
            local _name, restAfter = readToken(afterMarker)
            local flagStr = restAfter:match("^(%-?%d+)")
            if flagStr then
              isRegion = (tonumber(flagStr) & 1) ~= 0
            end
          end
          local key = (isRegion and "r:" or "m:") .. mIdxStr
          markerLaneOf[key] = last
          local guid = line:match("({%x%x%x%x%x%x%x%x%-[^}]+})")
          if guid then markerGuidOf[key] = guid end
        end
      end
    end
  end

  return laneNames, markerLaneOf, markerGuidOf
end

-- ════════════════════════════════════════════════════════════════════════
--  Marker / region enumeration
-- ════════════════════════════════════════════════════════════════════════
local function enumItems()
  local items = {}
  local _, numM, numR = r.CountProjectMarkers(0)
  for i = 0, numM + numR - 1 do
    local retval, isrgn, pos, rgnend, name, idx, color = r.EnumProjectMarkers3(0, i)
    if retval > 0 then
      items[#items+1] = {
        type    = isrgn and "r" or "m",
        pos     = pos,
        endPos  = isrgn and rgnend or nil,
        name    = name or "",
        idx     = idx,
        color   = color or 0,
        laneIdx = nil,   -- filled in by attachLanes if parsing succeeds
      }
    end
  end
  table.sort(items, function(a, b)
    if a.pos == b.pos then return a.type == "m" end  -- markers before regions at same pos
    return a.pos < b.pos
  end)
  return items
end

-- Try to attach a lane index to each item. Returns the laneNames table (may
-- be empty if no names were found). The "lane mode" of the GUI is then:
--   * If any item has a lane assignment AND laneNames has any entries → use
--     lane-based grouping.
--   * Otherwise → fall back to grouping by colour.
local function attachLanes(items)
  local laneNames, markerLaneOf, markerGuidOf = parseLaneInfo()
  for _, it in ipairs(items) do
    local key  = (it.type == "r" and "r:" or "m:") .. tostring(it.idx)
    it.laneIdx = markerLaneOf[key]
    it.guid    = markerGuidOf[key]
  end
  return laneNames
end

local function laneKeyForItem(it, byLane)
  if byLane and it.laneIdx ~= nil then
    return "L:" .. tostring(it.laneIdx)
  end
  return it.type .. ":" .. tostring(it.color)
end

local function groupLanes(items, laneNames)
  -- Decide mode: use lanes if at least one item has a laneIdx AND we have
  -- at least one named lane (otherwise the trailing-integer guess may be
  -- mis-parsing the GUID flags).
  local anyLane, namedLanes = false, false
  for _, it in ipairs(items) do
    if it.laneIdx ~= nil then anyLane = true; break end
  end
  for _ in pairs(laneNames or {}) do namedLanes = true; break end
  local byLane = anyLane and namedLanes

  local lanes, seen = {}, {}
  for _, it in ipairs(items) do
    local k = laneKeyForItem(it, byLane)
    if not seen[k] then
      local L = { key = k, items = {}, sample = {}, byLane = byLane }
      if byLane then
        L.laneIdx = it.laneIdx
        L.name    = (laneNames and laneNames[it.laneIdx]) or ("Lane " .. tostring(it.laneIdx))
      else
        L.type  = it.type
        L.color = it.color
      end
      seen[k] = L
      lanes[#lanes+1] = L
    end
    local L = seen[k]
    L.items[#L.items+1] = it
    if #L.sample < 3 and it.name ~= "" then L.sample[#L.sample+1] = it.name end
  end

  if byLane then
    table.sort(lanes, function(a, b) return (a.laneIdx or 0) < (b.laneIdx or 0) end)
  else
    table.sort(lanes, function(a, b)
      if a.type ~= b.type then return a.type == "r" end
      return (a.color or 0) > (b.color or 0)
    end)
  end
  return lanes, byLane
end

-- ════════════════════════════════════════════════════════════════════════
--  Classification (song / not song)
-- ════════════════════════════════════════════════════════════════════════
local function parseBlacklist(s)
  local list = {}
  for w in (s or ""):gmatch("[^,]+") do
    local t = w:match("^%s*(.-)%s*$")
    if t and t ~= "" then list[#list+1] = t:lower() end
  end
  return list
end

-- A blacklist entry vetoes a song match only if the marker name STARTS with
-- that word (case-insensitive), followed by a word boundary or end-of-name.
-- Anchored-at-start avoids false-positives like the "Intro" entry vetoing
-- "Élida Almeida: Intro zu Txika" — categorical markers in practice always
-- begin with the category word ("Beifall …", "Ansage …", "Intro", "Outro").
local function isBlacklisted(name, blacklist)
  if not name or name == "" then return false end
  local low = (name:lower():match("^%s*(.-)%s*$")) or name:lower()
  for _, b in ipairs(blacklist) do
    if #b > 0 and #b <= #low and low:sub(1, #b) == b then
      local nextCh = low:sub(#b + 1, #b + 1)
      if nextCh == "" or not nextCh:match("[%w]") then
        return true
      end
    end
  end
  return false
end

local function trimDisplayName(name, prefix)
  if prefix and prefix ~= "" and name:sub(1, #prefix) == prefix then
    name = name:sub(#prefix + 1)
  end
  return (name:match("^%s*(.-)%s*$")) or name
end

local function classify(items, blacklist, byLane)
  for _, it in ipairs(items) do
    local k = laneKeyForItem(it, byLane)
    local laneMatch   = proj.laneSong[k] == true
    local regionMatch = prefs.regionAsSong and it.type == "r"
    local prefixMatch = prefs.prefix ~= "" and it.name:sub(1, #prefs.prefix) == prefs.prefix
    local inferred    = laneMatch or regionMatch or prefixMatch
    if inferred and isBlacklisted(it.name, blacklist) then inferred = false end
    it.inferredSong = inferred
    -- Per-marker manual override (by GUID) takes precedence
    local ov = it.guid and proj.override[it.guid] or nil
    if ov == "s" then it.isSong = true
    elseif ov == "n" then it.isSong = false
    else it.isSong = inferred
    end
    it.hasOverride = (ov ~= nil)
  end
end

-- ════════════════════════════════════════════════════════════════════════
--  Length computation
-- ════════════════════════════════════════════════════════════════════════
local function projectEnd()
  local last = 0
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    local nItems = r.CountTrackMediaItems(tr)
    if nItems > 0 then
      local it = r.GetTrackMediaItem(tr, nItems - 1)
      local p = r.GetMediaItemInfo_Value(it, "D_POSITION") + r.GetMediaItemInfo_Value(it, "D_LENGTH")
      if p > last then last = p end
    end
  end
  return last
end

local function computeLengths(items)
  -- Regions: length = end - start
  -- Marker-songs: until next song (marker or region) on the timeline; if none, until project end
  local pe = projectEnd()
  for i, it in ipairs(items) do
    if it.isSong then
      if it.type == "r" and it.endPos then
        it.len = it.endPos - it.pos
      else
        local nextPos
        for j = i + 1, #items do
          if items[j].isSong then nextPos = items[j].pos; break end
        end
        if nextPos then
          it.len = nextPos - it.pos
        elseif pe > it.pos then
          it.len = pe - it.pos
        end
      end
    end
  end
end

-- ════════════════════════════════════════════════════════════════════════
--  Time formatting
-- ════════════════════════════════════════════════════════════════════════
local function fmtHMS(t)
  if not t or t < 0 then return "" end
  local h = math.floor(t / 3600)
  local m = math.floor((t % 3600) / 60)
  local s = math.floor(t % 60 + 0.5)
  if s == 60 then s = 0; m = m + 1 end
  if m == 60 then m = 0; h = h + 1 end
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

local function fmtBarBeat(pos)
  -- format_timestr_pos mode 2 -> measures.beats.fractionofbeat e.g. "12.3.50"
  local s = r.format_timestr_pos(pos, "", 2)
  local bar, beat = s:match("([^%.]+)%.([^%.]+)")
  if bar and beat then return bar .. "." .. beat end
  return s
end

local function fmtPos(t)
  if prefs.timeMode == "bar" then return fmtBarBeat(t) end
  return fmtHMS(t)
end

-- Lengths are always shown as duration (H:MM:SS) — bar-counts are ambiguous
-- across tempo changes; users care about "how long is this song" in seconds.
local function fmtLen(t)  return fmtHMS(t) end

-- ════════════════════════════════════════════════════════════════════════
--  Mini PDF writer (text-only, Helvetica + Helvetica-Bold, A4 portrait)
-- ════════════════════════════════════════════════════════════════════════
local PAGE_W, PAGE_H = 595, 842   -- A4 portrait in PDF points (1/72")
local MARGIN         = 50

-- UTF-8 → WinAnsi (CP1252) for Helvetica
local CP1252_3BYTE = {
  [0x2013] = 0x96, [0x2014] = 0x97,  -- en/em dash
  [0x2018] = 0x91, [0x2019] = 0x92,  -- single quotes
  [0x201C] = 0x93, [0x201D] = 0x94,  -- double quotes
  [0x20AC] = 0x80,                   -- euro
  [0x2026] = 0x85,                   -- ellipsis
  [0x2022] = 0x95,                   -- bullet
}

local function utf8ToWinAnsi(s)
  local out, i = {}, 1
  while i <= #s do
    local b1 = s:byte(i)
    if b1 < 0x80 then
      out[#out+1] = string.char(b1); i = i + 1
    elseif b1 < 0xC0 then
      i = i + 1  -- stray continuation byte
    elseif b1 < 0xE0 then
      local b2 = s:byte(i+1) or 0
      local cp = ((b1 - 0xC0) * 64) + (b2 - 0x80)
      out[#out+1] = (cp < 256) and string.char(cp) or "?"
      i = i + 2
    elseif b1 < 0xF0 then
      local b2 = s:byte(i+1) or 0
      local b3 = s:byte(i+2) or 0
      local cp = ((b1 - 0xE0) * 4096) + ((b2 - 0x80) * 64) + (b3 - 0x80)
      out[#out+1] = CP1252_3BYTE[cp] and string.char(CP1252_3BYTE[cp]) or "?"
      i = i + 3
    else
      out[#out+1] = "?"; i = i + 4
    end
  end
  return table.concat(out)
end

local function pdfEscape(s)
  -- escape PDF string-literal specials, then escape non-printable bytes as octal
  s = s:gsub("\\", "\\\\")
  s = s:gsub("%(", "\\(")
  s = s:gsub("%)", "\\)")
  s = s:gsub(".", function(c)
    local b = c:byte()
    if b < 32 or b > 126 then return string.format("\\%03o", b) end
    return c
  end)
  return s
end

-- Approximate Helvetica/Helvetica-Bold AFM widths (per 1000 em) for the chars
-- we actually need to right-align (digits, colon, dot, dash, space).
local HELV_W = {
  [0x20] = 278, [0x2E] = 278, [0x3A] = 278, [0x2D] = 333,
  [0x30] = 556, [0x31] = 556, [0x32] = 556, [0x33] = 556, [0x34] = 556,
  [0x35] = 556, [0x36] = 556, [0x37] = 556, [0x38] = 556, [0x39] = 556,
}
local HELVB_W = {
  [0x20] = 278, [0x2E] = 333, [0x3A] = 333, [0x2D] = 333,
  [0x30] = 556, [0x31] = 556, [0x32] = 556, [0x33] = 556, [0x34] = 556,
  [0x35] = 556, [0x36] = 556, [0x37] = 556, [0x38] = 556, [0x39] = 556,
}
local function textWidth(s, size, bold)
  local tab = bold and HELVB_W or HELV_W
  local w = 0
  for i = 1, #s do
    local cw = tab[s:byte(i)] or (bold and 611 or 556)  -- generic fallback
    w = w + cw
  end
  return w * size / 1000
end

-- Build a PDF from a list of pages. Each page is a list of ops:
--   {x=N, y=N, text=S, bold=bool, size=N}
local function buildPdf(pages)
  local objects = {}
  local function addObj(body) objects[#objects+1] = body; return #objects end

  -- Slot 1: Catalog, Slot 2: Pages (placeholder, filled later)
  addObj("<< /Type /Catalog /Pages 2 0 R >>")
  addObj("PLACEHOLDER")
  addObj("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
  addObj("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")

  local pageIds = {}
  for _, ops in ipairs(pages) do
    local buf = { "BT\n" }
    local curBold, curSize
    for _, op in ipairs(ops) do
      if op.bold ~= curBold or op.size ~= curSize then
        buf[#buf+1] = (op.bold and "/F2 " or "/F1 ") .. string.format("%g", op.size) .. " Tf\n"
        curBold, curSize = op.bold, op.size
      end
      buf[#buf+1] = string.format("1 0 0 1 %.2f %.2f Tm\n", op.x, op.y)
      buf[#buf+1] = "(" .. pdfEscape(utf8ToWinAnsi(op.text or "")) .. ") Tj\n"
    end
    buf[#buf+1] = "ET\n"
    local content = table.concat(buf)
    local contentId = addObj(string.format("<< /Length %d >>\nstream\n%s\nendstream", #content, content))
    local pageBody = string.format(
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] " ..
      "/Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents %d 0 R >>",
      PAGE_W, PAGE_H, contentId)
    pageIds[#pageIds+1] = addObj(pageBody)
  end

  local kidsList = {}
  for _, id in ipairs(pageIds) do kidsList[#kidsList+1] = tostring(id) .. " 0 R" end
  objects[2] = string.format("<< /Type /Pages /Kids [%s] /Count %d >>",
                             table.concat(kidsList, " "), #pageIds)

  local out = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n"
  local offsets = {}
  for i, body in ipairs(objects) do
    offsets[i] = #out
    out = out .. tostring(i) .. " 0 obj\n" .. body .. "\nendobj\n"
  end
  local xrefStart = #out
  out = out .. "xref\n0 " .. tostring(#objects + 1) .. "\n0000000000 65535 f \n"
  for i = 1, #objects do
    out = out .. string.format("%010d 00000 n \n", offsets[i])
  end
  out = out .. "trailer\n<< /Size " .. tostring(#objects + 1) .. " /Root 1 0 R >>\n"
        .. "startxref\n" .. tostring(xrefStart) .. "\n%%EOF\n"
  return out
end

-- ════════════════════════════════════════════════════════════════════════
--  Layout: build pages from rows
-- ════════════════════════════════════════════════════════════════════════
local function buildPages(rows, meta)
  -- rows[i] = { num="1", start="0:00", len="3:45", name="Song A", isSong=true }
  -- meta   = { title, subtitle, footerLines = {...} }
  local pages, ops = {}, {}
  pages[1] = ops

  local LM, RM, BM, TM = MARGIN, MARGIN, MARGIN, MARGIN
  local topBaseline = PAGE_H - TM - 14   -- baseline of first text line at top
  local botLimit    = BM + 40            -- don't draw rows below this baseline
  local LINE_H      = 16
  local FS_BODY     = 11
  local FS_HEAD     = 10
  local FS_TITLE    = 18
  local FS_SUB      = 10
  local FS_FOOT     = 9

  -- column right edges (right-aligned numerics)
  local X_NUM_R   = LM + 28
  local X_START_R = LM + 110
  local X_LEN_R   = LM + 185
  local X_NAME_L  = LM + 200
  local X_RIGHT   = PAGE_W - RM

  local function newPage()
    ops = {}
    pages[#pages+1] = ops
    return PAGE_H - TM - FS_HEAD
  end

  local function pushRightAligned(text, xRight, y, bold, size)
    if not text or text == "" then return end
    local w = textWidth(text, size, bold)
    ops[#ops+1] = { x = xRight - w, y = y, text = text, bold = bold, size = size }
  end

  -- Title block on page 1
  local y = topBaseline
  ops[#ops+1] = { x = LM, y = y, text = meta.title or "", bold = true, size = FS_TITLE }
  y = y - FS_TITLE - 2
  if meta.subtitle and meta.subtitle ~= "" then
    ops[#ops+1] = { x = LM, y = y, text = meta.subtitle, bold = false, size = FS_SUB }
    y = y - FS_SUB - 2
  end
  y = y - 14

  local function drawHeaderRow(yPos)
    pushRightAligned("#",     X_NUM_R,   yPos, true, FS_HEAD)
    pushRightAligned("Start", X_START_R, yPos, true, FS_HEAD)
    pushRightAligned("Länge", X_LEN_R,   yPos, true, FS_HEAD)
    ops[#ops+1] = { x = X_NAME_L, y = yPos, text = "Name", bold = true, size = FS_HEAD }
  end

  drawHeaderRow(y)
  y = y - LINE_H

  for _, row in ipairs(rows) do
    if y < botLimit then
      y = newPage()
      drawHeaderRow(y)
      y = y - LINE_H
    end
    local bold = row.isSong == true
    pushRightAligned(row.num,   X_NUM_R,   y, bold, FS_BODY)
    pushRightAligned(row.start, X_START_R, y, bold, FS_BODY)
    pushRightAligned(row.len,   X_LEN_R,   y, bold, FS_BODY)
    if row.name and row.name ~= "" then
      ops[#ops+1] = { x = X_NAME_L, y = y, text = row.name, bold = bold, size = FS_BODY }
    end
    y = y - LINE_H
  end

  -- Footer on every page: page X/Y left, dateline right
  local totalPages = #pages
  for pIdx, pageOps in ipairs(pages) do
    local fy = BM - 4
    pageOps[#pageOps+1] = { x = LM, y = fy,
      text = string.format("Page %d / %d", pIdx, totalPages),
      bold = false, size = FS_FOOT }
    if meta.dateline and meta.dateline ~= "" then
      local w = textWidth(meta.dateline, FS_FOOT, false)
      pageOps[#pageOps+1] = { x = X_RIGHT - w, y = fy,
        text = meta.dateline, bold = false, size = FS_FOOT }
    end
  end

  -- Stats footer (above page number) on last page only
  if meta.footerLines and #meta.footerLines > 0 then
    local last = pages[#pages]
    local yy = BM + 12
    for i = #meta.footerLines, 1, -1 do
      last[#last+1] = { x = LM, y = yy, text = meta.footerLines[i], bold = (i == 1), size = FS_FOOT + 1 }
      yy = yy + 12
    end
  end

  return pages
end

-- ════════════════════════════════════════════════════════════════════════
--  Row building
-- ════════════════════════════════════════════════════════════════════════
local function buildRowsAndStats()
  local items     = enumItems()
  local laneNames = attachLanes(items)
  local _, byLane = groupLanes(items, laneNames)
  local blacklist = parseBlacklist(prefs.blacklist)
  classify(items, blacklist, byLane)

  -- Filter by include-lanes
  local visible = {}
  for _, it in ipairs(items) do
    if proj.laneInclude[laneKeyForItem(it, byLane)] ~= false then  -- default = included
      visible[#visible+1] = it
    end
  end

  computeLengths(visible)

  local songCount, netMusic = 0, 0
  local rows = {}
  local songNum = 0
  for _, it in ipairs(visible) do
    local row = {
      pos         = it.pos,
      start       = fmtPos(it.pos),
      name        = trimDisplayName(it.name, prefs.prefix),
      isSong      = it.isSong,
      guid        = it.guid,
      inferredSong= it.inferredSong,
      hasOverride = it.hasOverride,
    }
    if it.isSong then
      songNum = songNum + 1
      songCount = songCount + 1
      row.num = tostring(songNum)
      if it.len then
        row.len    = fmtLen(it.len)
        netMusic   = netMusic + it.len
      end
    end
    rows[#rows+1] = row
  end

  local brutto = 0
  if #visible > 0 then
    local first, last = math.huge, -math.huge
    for _, it in ipairs(visible) do
      if it.pos < first then first = it.pos end
      local e = it.endPos or it.pos
      if e > last then last = e end
    end
    if first < last then brutto = last - first end
  end

  return rows, {
    songCount = songCount,
    netMusic  = netMusic,
    brutto    = brutto,
    total     = #items,
    shown     = #visible,
  }
end

-- ════════════════════════════════════════════════════════════════════════
--  File helpers
-- ════════════════════════════════════════════════════════════════════════
local function projectFilePath()
  local _, path = r.EnumProjects(-1, "")
  return path or ""
end

local function projectName()
  local p = projectFilePath()
  if p == "" then return "Untitled Project" end
  return p:match("([^/\\]+)%.[Rr][Pp][Pp]$") or p:match("([^/\\]+)$") or "Project"
end

local function projectDir()
  local p = projectFilePath()
  if p == "" then return "" end
  return p:match("(.*[/\\])") or ""
end

local function defaultPdfPath()
  local d = projectDir()
  local n = projectName()
  if d == "" then
    -- unsaved project — fall back to resource path
    d = r.GetResourcePath() .. "/"
  end
  return d .. n .. " - Setlist.pdf"
end

local function writeFile(path, bytes)
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  f:write(bytes)
  f:close()
  return true
end

local function openInOS(path)
  local osn = r.GetOS()
  local cmd
  if osn:find("OSX") or osn:find("macOS") then
    cmd = 'open "' .. path .. '"'
  elseif osn:find("Win") then
    cmd = 'start "" "' .. path .. '"'
  else
    cmd = 'xdg-open "' .. path .. '" &'
  end
  os.execute(cmd)
end

-- ════════════════════════════════════════════════════════════════════════
--  Export actions
-- ════════════════════════════════════════════════════════════════════════
local function makeMeta(stats)
  local m = {
    title    = projectName(),
    subtitle = "Concert Setlist / Marker & Region Export",
    dateline = "Exported " .. os.date("%Y-%m-%d %H:%M"),
    footerLines = {
      string.format("Songs: %d   ·   Net music: %s   ·   Gross duration: %s",
                    stats.songCount, fmtHMS(stats.netMusic), fmtHMS(stats.brutto)),
      string.format("%d of %d items shown.", stats.shown, stats.total),
    },
  }
  return m
end

local function exportPdf(targetPath)
  local rows, stats = buildRowsAndStats()
  if #rows == 0 then
    state.status = "No markers or regions to export."
    return
  end
  local pages = buildPages(rows, makeMeta(stats))
  local pdf   = buildPdf(pages)
  local path  = targetPath or defaultPdfPath()
  local ok, err = writeFile(path, pdf)
  if not ok then
    state.status = "Write failed: " .. tostring(err)
    return
  end
  openInOS(path)
  state.status = string.format("Wrote %d rows (%d songs) → %s",
                               #rows, stats.songCount, path)
end

local function exportText()
  local rows, stats = buildRowsAndStats()
  if #rows == 0 then
    state.status = "No markers or regions to copy."
    return
  end
  local lines = {}
  for _, row in ipairs(rows) do
    lines[#lines+1] = string.format("%s\t%s\t%s\t%s",
      row.num or "", row.start or "", row.len or "", row.name or "")
  end
  lines[#lines+1] = ""
  lines[#lines+1] = string.format("Project: %s   Exported %s",
    projectName(), os.date("%Y-%m-%d"))
  lines[#lines+1] = string.format("Songs: %d   Net music: %s   Gross: %s",
    stats.songCount, fmtHMS(stats.netMusic), fmtHMS(stats.brutto))
  r.CF_SetClipboard(table.concat(lines, "\n"))
  state.status = string.format("Copied %d rows to clipboard.", #rows)
end

local function saveAsPdf()
  local default = defaultPdfPath()
  local retval, path = r.JS_Dialog_BrowseForSaveFile("Save Concert PDF", projectDir(), default, "PDF (.pdf)\0*.pdf\0\0")
  if retval == 1 and path and path ~= "" then
    if not path:lower():match("%.pdf$") then path = path .. ".pdf" end
    exportPdf(path)
  end
end

-- ════════════════════════════════════════════════════════════════════════
--  GUI
-- ════════════════════════════════════════════════════════════════════════
local ctx  = r.ImGui_CreateContext("JG Concert Marker/Region Export")
local font = r.ImGui_CreateFont("sans-serif", 14)
r.ImGui_Attach(ctx, font)

local function colorSwatch(reaperColor)
  -- Reaper colours are 0xRRGGBB with 0x1000000 "set" flag, or 0 = default
  local c = reaperColor or 0
  if c == 0 then return 0xCCCCCCFF end
  local rr, gg, bb = r.ColorFromNative(c & 0xFFFFFF)
  return ((rr & 0xFF) << 24) | ((gg & 0xFF) << 16) | ((bb & 0xFF) << 8) | 0xFF
end

local function laneLabel(L)
  if L.byLane then
    return string.format("%s — %d items", L.name or "(unnamed)", #L.items)
  end
  local typeLabel = (L.type == "r") and "Regions" or "Markers"
  local colorLabel
  if (L.color or 0) == 0 then
    colorLabel = "(no colour)"
  else
    local rr, gg, bb = r.ColorFromNative(L.color & 0xFFFFFF)
    colorLabel = string.format("#%02X%02X%02X", rr, gg, bb)
  end
  return string.format("%s %s — %d items", typeLabel, colorLabel, #L.items)
end

local function drawLaneTable(lanes, byLane)
  if #lanes == 0 then
    r.ImGui_TextDisabled(ctx, "No markers or regions in this project.")
    return
  end
  if r.ImGui_BeginTable(ctx, "lanes", 4,
       r.ImGui_TableFlags_Borders() | r.ImGui_TableFlags_RowBg()) then
    r.ImGui_TableSetupColumn(ctx, "Inc",    r.ImGui_TableColumnFlags_WidthFixed(), 40)
    r.ImGui_TableSetupColumn(ctx, "Song",   r.ImGui_TableColumnFlags_WidthFixed(), 50)
    r.ImGui_TableSetupColumn(ctx, "Lane",   r.ImGui_TableColumnFlags_WidthFixed(), 260)
    r.ImGui_TableSetupColumn(ctx, "Sample names")
    r.ImGui_TableHeadersRow(ctx)
    for _, L in ipairs(lanes) do
      r.ImGui_TableNextRow(ctx)
      local inc  = proj.laneInclude[L.key]; if inc  == nil then inc  = true end
      local song = proj.laneSong[L.key]   ; if song == nil then song = false end

      r.ImGui_TableSetColumnIndex(ctx, 0)
      local chgI, vI = r.ImGui_Checkbox(ctx, "##inc"..L.key, inc)
      if chgI then proj.laneInclude[L.key] = vI; projDirty = true end

      r.ImGui_TableSetColumnIndex(ctx, 1)
      local chgS, vS = r.ImGui_Checkbox(ctx, "##sng"..L.key, song)
      if chgS then proj.laneSong[L.key] = vS; projDirty = true end

      r.ImGui_TableSetColumnIndex(ctx, 2)
      if not L.byLane then
        local swatch = colorSwatch(L.color)
        r.ImGui_ColorButton(ctx, "##sw"..L.key, swatch,
          r.ImGui_ColorEditFlags_NoTooltip() | r.ImGui_ColorEditFlags_NoPicker(), 14, 14)
        r.ImGui_SameLine(ctx)
      end
      r.ImGui_Text(ctx, laneLabel(L))

      r.ImGui_TableSetColumnIndex(ctx, 3)
      r.ImGui_Text(ctx, table.concat(L.sample, ", "))
    end
    r.ImGui_EndTable(ctx)
  end
end

-- Per-row preview table: shows exactly what the PDF will contain, with a
-- per-marker Song toggle that overrides the auto-classification. Toggling
-- back to the inferred value removes the override (so it doesn't linger).
local function togglePreviewOverride(row)
  if not row.guid then return end
  local newSong = not row.isSong
  if newSong == row.inferredSong then
    proj.override[row.guid] = nil
  else
    proj.override[row.guid] = newSong and "s" or "n"
  end
  projDirty = true
end

local function drawPreviewTable(rows)
  if #rows == 0 then
    r.ImGui_TextDisabled(ctx, "(Nothing to preview — adjust lanes or save the project first.)")
    return
  end
  local childFlags = (r.ImGui_ChildFlags_Border and r.ImGui_ChildFlags_Border()) or 0
  if r.ImGui_BeginChild(ctx, "preview_scroll", 0, 260, childFlags) then
    if r.ImGui_BeginTable(ctx, "preview", 5,
         r.ImGui_TableFlags_Borders() | r.ImGui_TableFlags_RowBg()) then
      r.ImGui_TableSetupColumn(ctx, "Song",  r.ImGui_TableColumnFlags_WidthFixed(), 46)
      r.ImGui_TableSetupColumn(ctx, "#",     r.ImGui_TableColumnFlags_WidthFixed(), 30)
      r.ImGui_TableSetupColumn(ctx, "Start", r.ImGui_TableColumnFlags_WidthFixed(), 70)
      r.ImGui_TableSetupColumn(ctx, "Länge", r.ImGui_TableColumnFlags_WidthFixed(), 60)
      r.ImGui_TableSetupColumn(ctx, "Name")
      r.ImGui_TableHeadersRow(ctx)
      for i, row in ipairs(rows) do
        r.ImGui_TableNextRow(ctx)
        r.ImGui_TableSetColumnIndex(ctx, 0)
        if row.guid then
          local chg, v = r.ImGui_Checkbox(ctx, "##psng"..i, row.isSong)
          if chg then
            row.isSong = v
            togglePreviewOverride(row)
          end
        else
          r.ImGui_TextDisabled(ctx, row.isSong and "S" or "·")
        end
        r.ImGui_TableSetColumnIndex(ctx, 1)
        r.ImGui_Text(ctx, row.num or "")
        r.ImGui_TableSetColumnIndex(ctx, 2)
        r.ImGui_Text(ctx, row.start or "")
        r.ImGui_TableSetColumnIndex(ctx, 3)
        r.ImGui_Text(ctx, row.len or "")
        r.ImGui_TableSetColumnIndex(ctx, 4)
        local name = row.name or ""
        if row.hasOverride then name = name .. "  *" end
        r.ImGui_Text(ctx, name)
      end
      r.ImGui_EndTable(ctx)
    end
    r.ImGui_EndChild(ctx)
  end
  r.ImGui_TextDisabled(ctx, "  Click the Song checkbox to override auto-detection per marker. Asterisk = active override.")
end

-- Debug: dump the marker-related lines of the project chunk so the user
-- can share the format for further parsing work. Prefers clipboard (SWS)
-- and falls back to writing a text file next to the .rpp.
local function dumpChunk()
  local raw = getProjectChunkMarkerSection()
  if raw == "" then
    state.status = "Could not read project chunk (unsaved project? install SWS or save the .rpp)."
    return
  end
  if r.CF_SetClipboard then
    r.CF_SetClipboard(raw)
    state.status = "Copied marker chunk lines to clipboard — paste them back to me."
    return
  end
  local dir = projectDir()
  if dir == "" then dir = r.GetResourcePath() .. "/" end
  local out = dir .. projectName() .. " - chunk-dump.txt"
  local ok = writeFile(out, raw)
  if ok then
    state.status = "Chunk dump written to: " .. out
  else
    state.status = "Failed to write chunk dump."
  end
end

local function drawGUI()
  r.ImGui_TextWrapped(ctx,
    "Exports markers and regions as a printable PDF. Songs are detected by " ..
    "the strategies below (OR-combined; blacklist acts as veto) and rendered " ..
    "in bold with a running number.")

  r.ImGui_Separator(ctx)

  -- Time mode
  r.ImGui_Text(ctx, "Time base:"); r.ImGui_SameLine(ctx)
  if r.ImGui_RadioButton(ctx, "H:MM:SS", prefs.timeMode == "time") then
    if prefs.timeMode ~= "time" then prefs.timeMode = "time"; prefsDirty = true end
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_RadioButton(ctx, "bar.beat", prefs.timeMode == "bar") then
    if prefs.timeMode ~= "bar" then prefs.timeMode = "bar"; prefsDirty = true end
  end

  -- Region-as-song
  local chgR, vR = r.ImGui_Checkbox(ctx, "Regions count as songs", prefs.regionAsSong)
  if chgR then prefs.regionAsSong = vR; prefsDirty = true end

  -- Prefix (label before field)
  r.ImGui_Text(ctx, "Song prefix trigger:")
  r.ImGui_SameLine(ctx)
  r.ImGui_PushItemWidth(ctx, 100)
  local chgP, vP = r.ImGui_InputText(ctx, "##prefix", prefs.prefix or "")
  if chgP then prefs.prefix = vP; prefsDirty = true end
  r.ImGui_PopItemWidth(ctx)
  r.ImGui_SameLine(ctx)
  r.ImGui_TextDisabled(ctx, "(empty = off; e.g. \"*\" or \"♪\")")

  -- Blacklist (label before field, full width)
  r.ImGui_Text(ctx, "Blacklist (comma-separated; matches word at START of name; vetoes any song match):")
  r.ImGui_PushItemWidth(ctx, -1)
  local chgB, vB = r.ImGui_InputText(ctx, "##blacklist", prefs.blacklist or "")
  if chgB then prefs.blacklist = vB; prefsDirty = true end
  r.ImGui_PopItemWidth(ctx)

  r.ImGui_Separator(ctx)

  -- Lane table — uses Reaper-7 named lanes if detectable in the project
  -- chunk, otherwise groups by (type + colour) as a fallback.
  local items     = enumItems()
  local laneNames = attachLanes(items)
  local lanes, byLane = groupLanes(items, laneNames)
  if byLane then
    r.ImGui_Text(ctx, "Lanes (from project ruler lanes):")
  else
    r.ImGui_Text(ctx, "Lanes (grouped by type + colour — no named lanes detected):")
  end
  r.ImGui_TextDisabled(ctx, "  Inc = include in export    Song = treat this lane as songs")
  drawLaneTable(lanes, byLane)

  r.ImGui_Separator(ctx)

  -- Live preview of exported rows with per-marker override toggle
  local previewRows, previewStats = buildRowsAndStats()
  r.ImGui_Text(ctx, string.format(
    "Preview — %d rows, %d songs   ·   Net %s   ·   Gross %s",
    #previewRows, previewStats.songCount,
    fmtHMS(previewStats.netMusic), fmtHMS(previewStats.brutto)))
  drawPreviewTable(previewRows)

  r.ImGui_Separator(ctx)

  if r.ImGui_Button(ctx, "Export PDF", 130, 28) then exportPdf(nil) end
  r.ImGui_SameLine(ctx)
  if r.JS_Dialog_BrowseForSaveFile then
    if r.ImGui_Button(ctx, "Save As…", 100, 28) then saveAsPdf() end
    r.ImGui_SameLine(ctx)
  end
  if r.CF_SetClipboard then
    if r.ImGui_Button(ctx, "Copy as Text", 120, 28) then exportText() end
    r.ImGui_SameLine(ctx)
  end
  if r.ImGui_Button(ctx, "Debug: dump chunk", 150, 28) then dumpChunk() end

  r.ImGui_Spacing(ctx)
  r.ImGui_TextWrapped(ctx, state.status or "")
end

local function loop()
  r.ImGui_PushFont(ctx, font, 14)
  r.ImGui_SetNextWindowSize(ctx, 760, 820, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, "JG Concert Marker/Region Export", true)
  if visible then
    drawGUI()
    r.ImGui_End(ctx)
  end
  r.ImGui_PopFont(ctx)

  if prefsDirty then savePrefs(); prefsDirty = false end
  if projDirty  then saveProj();  projDirty  = false end
  if open then r.defer(loop) end
end

-- Entry
loadPrefs()
loadProj()
r.atexit(function() savePrefs(); saveProj() end)
loop()
