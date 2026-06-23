-- @description SRC Source Position HUD (live source-file position under cursor, edit-proof jump-to)
-- @author JG
-- @version 1.0.4
-- @about
--   A floating HUD that shows, live, the SOURCE-FILE position under the edit
--   (or play) cursor and lets you JUMP to a source position by typing it. The
--   jump is computed from the SRC item's *current* timeline position + start
--   offset, so it stays correct after ripple cuts, moves and other edits —
--   unlike the native "Go to time" which is timeline-absolute.
--
--   Anchor is a dedicated SRC track holding the source material (which gets cut
--   into several items during editing). On first start the currently selected
--   track is turned into the SRC track (renamed "SRC", coloured red, moved to
--   the top and pinned to the top of the TCP). Its GUID is stored in the
--   project so it is recognised again across restarts; a second invocation
--   toggles the HUD closed.
--
--   Pinning uses the native action 40000 "Track: Pin tracks to top of arrange
--   view" (REAPER 7.46+), guarded by the B_TCPPIN state so re-runs never toggle
--   it off; other pins (incl. the master) are untouched. On older builds the
--   track is still moved to the top, just not pinned.
--
--   Tip: leave the SRC items UN-glued while editing — a glued item's offset
--   would point into the glue file, not the original source.
--
--   Requires ReaImGui (install via ReaPack: Extensions > ReaPack > Browse
--   packages > "ReaImGui").

local r = reaper

-- ════════════════════════════════════════════════════════════════════════
--  Dependency check
-- ════════════════════════════════════════════════════════════════════════
if not r.ImGui_CreateContext then
  r.MB("This script requires ReaImGui.\n\n" ..
       "Install it via ReaPack:\n" ..
       "Extensions > ReaPack > Browse packages > \"ReaImGui\".",
       "Missing dependency", 0)
  return
end

-- ════════════════════════════════════════════════════════════════════════
--  Constants
-- ════════════════════════════════════════════════════════════════════════
local VERSION   = "1.0.4"
local WIN_TITLE = "JG SRC Position HUD  (v" .. VERSION .. ")"

local SECTION  = "SRC_HUD"      -- ExtState / ProjExtState section
local KEY_GUID = "track_guid"   -- project key holding the SRC track GUID
local RUN_FLAG = "running"      -- global key: HUD instance is deferring

-- ════════════════════════════════════════════════════════════════════════
--  Toggle: a running HUD closes on the second invocation (no second window)
-- ════════════════════════════════════════════════════════════════════════
if r.GetExtState(SECTION, RUN_FLAG) == "1" then
  r.SetExtState(SECTION, RUN_FLAG, "0", false)   -- ask the running instance to quit
  return
end

local _, _, sectionID, cmdID = r.get_action_context()

-- ════════════════════════════════════════════════════════════════════════
--  Track helpers
-- ════════════════════════════════════════════════════════════════════════
local function findTrackByGUID(guid)
  if not guid or guid == "" then return nil end
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    if r.GetTrackGUID(tr) == guid then return tr end
  end
  return nil
end

local function saveSel()
  local s = {}
  for i = 0, r.CountSelectedTracks(0) - 1 do s[#s + 1] = r.GetSelectedTrack(0, i) end
  return s
end

local function restoreSel(s)
  for i = 0, r.CountTracks(0) - 1 do r.SetTrackSelected(r.GetTrack(0, i), false) end
  for _, tr in ipairs(s) do r.SetTrackSelected(tr, true) end
end

-- Source filename of a take; resolves SECTION/reversed takes to their parent so
-- the filename still matches (position math is approximate for those).
local function takeSourceFile(take)
  if not take or r.TakeIsMIDI(take) then return "" end
  local src = r.GetMediaItemTake_Source(take)
  if not src then return "" end
  if r.GetMediaSourceType(src, "") == "SECTION" and r.GetMediaSourceParent then
    local parent = r.GetMediaSourceParent(src)
    if parent then src = parent end
  end
  return r.GetMediaSourceFileName(src, "")
end

-- Apply the SRC look idempotently (only touches what is off).
local function applySRCStyle(tr)
  r.PreventUIRefresh(1)
  local _, nm = r.GetTrackName(tr)
  if nm ~= "SRC" then
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", "SRC", true)
  end
  local wantColor = r.ColorToNative(255, 0, 0) | 0x1000000
  if r.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR") ~= wantColor then
    r.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", wantColor)
  end
  if r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") ~= 1 then  -- not already on top
    local sel = saveSel()
    r.SetOnlyTrackSelected(tr)
    r.ReorderSelectedTracks(0, 0)
    restoreSel(sel)
  end
  -- Pin to top (REAPER 7.46+). 40000 = "Track: Pin tracks to top of arrange
  -- view" — leaves other pins (incl. the master) intact, unlike 40008. Guarded
  -- by the B_TCPPIN state so an already-pinned SRC is never toggled back off;
  -- the getter pcall also no-ops cleanly on pre-7.46 builds (40000 is unassigned
  -- there, so the Main_OnCommand is harmless).
  local alreadyPinned = false
  pcall(function() alreadyPinned = r.GetMediaTrackInfo_Value(tr, "B_TCPPIN") == 1 end)
  if not alreadyPinned then
    local sel = saveSel()
    r.SetOnlyTrackSelected(tr)
    r.Main_OnCommand(40000, 0)   -- Track: Pin tracks to top of arrange view
    restoreSel(sel)
  end
  r.PreventUIRefresh(-1)
  r.TrackList_AdjustWindows(false)
end

-- ════════════════════════════════════════════════════════════════════════
--  SRC setup at start
-- ════════════════════════════════════════════════════════════════════════
local function setupSRC()
  -- 1) stored GUID → reuse without asking, re-apply styling idempotently
  local _, guid = r.GetProjExtState(0, SECTION, KEY_GUID)
  local tr = findTrackByGUID(guid)
  if tr then
    r.Undo_BeginBlock()
    applySRCStyle(tr)
    r.Undo_EndBlock("SRC HUD: re-apply SRC styling", -1)
    return tr
  end

  -- 2) else use the single selected track
  if r.CountSelectedTracks(0) ~= 1 then
    r.MB("Please select exactly one source track and run the script again.",
         "SRC HUD", 0)
    return nil
  end
  tr = r.GetSelectedTrack(0, 0)
  local _, nm = r.GetTrackName(tr)
  if r.MB(("Set up the selected track \"%s\" as SRC?"):format(nm), "SRC HUD", 4) ~= 6 then
    return nil   -- 6 = Yes; anything else = abort
  end
  r.Undo_BeginBlock()
  applySRCStyle(tr)
  r.SetProjExtState(0, SECTION, KEY_GUID, r.GetTrackGUID(tr))
  r.Undo_EndBlock("SRC HUD: set up track as SRC", -1)
  return tr
end

local srcTrack = setupSRC()
if not srcTrack then return end
local srcGUID = r.GetTrackGUID(srcTrack)

-- We are committed to running — claim the toggle slot and register cleanup.
r.SetExtState(SECTION, RUN_FLAG, "1", false)
r.SetToggleCommandState(sectionID, cmdID, 1)
r.RefreshToolbar2(sectionID, cmdID)

local function shutdown()
  r.SetExtState(SECTION, RUN_FLAG, "0", false)
  r.SetToggleCommandState(sectionID, cmdID, 0)
  r.RefreshToolbar2(sectionID, cmdID)
end
r.atexit(shutdown)

-- ════════════════════════════════════════════════════════════════════════
--  Position maths (verbatim per spec)
--    src = offs + (cursor - pos) * rate
--    t   = pos  + (s - offs) / rate
--    hit:  offs <= s < offs + D_LENGTH * rate
-- ════════════════════════════════════════════════════════════════════════
local function refPos()
  local ps = r.GetPlayState()
  if (ps & 1) ~= 0 then return r.GetPlayPosition() end   -- playing/recording
  return r.GetCursorPosition()
end

-- The SRC item under a project-time cursor → file, source position.
local function srcUnderCursor(track, cursor)
  for i = 0, r.CountTrackMediaItems(track) - 1 do
    local item = r.GetTrackMediaItem(track, i)
    local pos  = r.GetMediaItemInfo_Value(item, "D_POSITION")
    local len  = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    if cursor >= pos and cursor < pos + len then
      local take = r.GetActiveTake(item)
      local file = takeSourceFile(take)
      if file ~= "" then
        local offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
        local rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
        return file, offs + (cursor - pos) * rate
      end
    end
  end
  return nil, nil
end

-- On the SRC track, find the item of `file` whose source range contains `s` and
-- return the timeline time to jump to. On overlap, the one nearest `cursor` wins.
local function timelineForSource(track, file, s, cursor)
  local bestT, bestDist = nil, math.huge
  for i = 0, r.CountTrackMediaItems(track) - 1 do
    local item = r.GetTrackMediaItem(track, i)
    local take = r.GetActiveTake(item)
    if takeSourceFile(take) == file then
      local pos  = r.GetMediaItemInfo_Value(item, "D_POSITION")
      local len  = r.GetMediaItemInfo_Value(item, "D_LENGTH")
      local offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
      local rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
      if s >= offs and s < offs + len * rate then
        local t = pos + (s - offs) / rate
        local d = math.abs(t - cursor)
        if d < bestDist then bestT, bestDist = t, d end
      end
    end
  end
  return bestT
end

-- ════════════════════════════════════════════════════════════════════════
--  Formatting
-- ════════════════════════════════════════════════════════════════════════
local function fmt(t)
  if not t then return "—:—:—.———" end
  local neg = t < 0
  t = math.abs(t)
  local h = math.floor(t / 3600)
  local m = math.floor((t % 3600) / 60)
  local s = t % 60
  return string.format("%s%d:%02d:%06.3f", neg and "-" or "", h, m, s)
end

local function basename(p)
  return (p or ""):match("[^/\\]+$") or (p or "")
end

-- A bare digit run of 4+ chars is compact mmss / hmmss / hhmmss; anything else
-- (": " / "." / short numbers) goes to REAPER's hh:mm:ss.xxx / plain-seconds parser.
local function parseClock(str)
  str = (str or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if str:find("^%d+$") and #str >= 4 then
    local n  = #str
    local ss = tonumber(str:sub(-2))
    local mm = tonumber(str:sub(-4, -3))
    local hh = (n > 4) and tonumber(str:sub(1, n - 4)) or 0
    return hh * 3600 + mm * 60 + ss
  end
  return r.parse_timestr(str)
end

-- ════════════════════════════════════════════════════════════════════════
--  GUI
-- ════════════════════════════════════════════════════════════════════════
local ctx  = r.ImGui_CreateContext("JG SRC HUD")
local font = r.ImGui_CreateFont("sans-serif", 14)
r.ImGui_Attach(ctx, font)

local jumpStr    = ""
local status     = "Move the cursor over the SRC track."
-- last source file seen under the cursor; shared with JG_SRC_Jump_To_Source_Position
-- via project ExtState "last_file" and seeded from it on start.
local stickyFile = select(2, r.GetProjExtState(0, SECTION, "last_file"))
if stickyFile == "" then stickyFile = nil end

local function doJump()
  if not stickyFile then status = "No SRC source detected yet."; return end
  local s = parseClock(jumpStr)                  -- "5:00", "1:02:03", "1126", "90" …
  local t = timelineForSource(srcTrack, stickyFile, s, refPos())
  if t then
    r.SetEditCurPos(t, true, false)              -- move cursor + follow view
    status = ("→ %s @ %s"):format(basename(stickyFile), fmt(s))
  else
    status = ("%s not found in %s"):format(fmt(s), basename(stickyFile))
  end
end

local function resetSRC()
  if r.ValidatePtr2(0, srcTrack, "MediaTrack*") then
    r.Undo_BeginBlock()
    pcall(function() r.SetMediaTrackInfo_Value(srcTrack, "B_TCPPIN", 0) end)
    r.SetMediaTrackInfo_Value(srcTrack, "I_CUSTOMCOLOR", 0)
    r.GetSetMediaTrackInfo_String(srcTrack, "P_NAME", "", true)
    r.Undo_EndBlock("SRC HUD: remove SRC marking", -1)
    r.TrackList_AdjustWindows(false)
  end
  r.SetProjExtState(0, SECTION, KEY_GUID, "")
  status = "SRC marking removed (name/colour/pin)."
end

local function draw()
  -- keep the SRC pointer valid across track reordering/closing of the project
  if not r.ValidatePtr2(0, srcTrack, "MediaTrack*") then
    srcTrack = findTrackByGUID(srcGUID)
    if not srcTrack then
      r.ImGui_TextColored(ctx, 0xFF6060FF, "SRC track no longer exists.")
      return
    end
  end

  local cursor = refPos()
  local file, s = srcUnderCursor(srcTrack, cursor)
  if file and file ~= stickyFile then
    stickyFile = file
    r.SetProjExtState(0, SECTION, "last_file", file)  -- share with the jump dialog
  end

  if file then
    r.ImGui_Text(ctx, "Source file:  " .. basename(file))
    r.ImGui_Text(ctx, "Source pos.:  " .. fmt(s))
  else
    r.ImGui_TextColored(ctx, 0x909090FF, "Source file:  — (no SRC source under cursor)")
    if stickyFile then
      r.ImGui_TextColored(ctx, 0x909090FF, "last seen:    " .. basename(stickyFile))
    else
      r.ImGui_Text(ctx, "")
    end
  end
  r.ImGui_Text(ctx, "Timeline:     " .. fmt(cursor))

  r.ImGui_Separator(ctx)

  r.ImGui_Text(ctx, "Jump to (source time):")
  r.ImGui_SetNextItemWidth(ctx, 150)
  local enter
  enter, jumpStr = r.ImGui_InputText(ctx, "##jump", jumpStr,
                                     r.ImGui_InputTextFlags_EnterReturnsTrue())
  r.ImGui_SameLine(ctx)
  local clicked = r.ImGui_Button(ctx, "Jump", 80, 0)
  if enter or clicked then doJump() end

  r.ImGui_Spacing(ctx)
  r.ImGui_TextWrapped(ctx, status)

  r.ImGui_Separator(ctx)
  if r.ImGui_SmallButton(ctx, "Reset SRC") then resetSRC() end
end

local function loop()
  r.ImGui_PushFont(ctx, font, 14)
  r.ImGui_SetNextWindowSize(ctx, 380, 240, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, WIN_TITLE, true)
  if visible then
    draw()
    r.ImGui_End(ctx)
  end
  r.ImGui_PopFont(ctx)

  -- Close on the window X, or when a second invocation cleared the run flag.
  -- Closing leaves the SRC track untouched (no auto-reset) — by design.
  if open and r.GetExtState(SECTION, RUN_FLAG) == "1" then
    r.defer(loop)
  end
end

loop()
