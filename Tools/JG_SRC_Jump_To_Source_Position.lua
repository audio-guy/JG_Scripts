-- @description SRC Jump To Source Position (edit-proof source jump + SRC setup, one window)
-- @author JG
-- @version 1.2.0
-- @provides [main] .
-- @about
--   A small, keyboard-first "Jump to" dialog that jumps the edit cursor to a
--   SOURCE-file position on a dedicated SRC track. Unlike REAPER's native 40069
--   (timeline-absolute), the target is computed from the SRC item's CURRENT
--   position + start offset, so the same source time keeps landing on the same
--   content after ripple cuts and moves.
--
--   Self-contained, made to be bound to a shortcut:
--     * On first use it turns the single selected track into the SRC anchor
--       (renamed "SRC", coloured red, moved to the top and pinned via the native
--       action 40000 on REAPER 7.46+). Its GUID is stored in the project, so it
--       is recognised again across restarts; later runs go straight to the jump.
--     * The input field is auto-focused so you can type immediately. Enter jumps
--       to the occurrence nearest the cursor; if the same source time exists more
--       than once on SRC (e.g. duplicated material from editing), pressing Enter
--       again cycles to the next-later occurrence and wraps to the first after the
--       last, keeping the window open. With a single occurrence Enter jumps and
--       closes. Esc closes; a not-found time keeps the window open.
--
--   Accepted input (the source-meaningful subset of 40069):
--     mmss            last two = seconds, rest = minutes (11637 = 116:37)
--     hhmmss          exactly six digits = h:mm:ss (011637 = 1:16:37)
--     mm:ss.xxx       minutes:seconds.fraction
--     h:mm:ss.xxx     hours:minutes:seconds.fraction
--     123.4           plain seconds
--     +val / -val     relative to the current source position under the cursor
--
--   Target file = the SRC source under the edit/play cursor; if the cursor sits
--   in a gap, the file last jumped to, or — if the SRC track holds a single
--   source — that one. "Reset SRC" removes the SRC marking again.
--
--   Tip: leave the SRC items UN-glued while editing — a glued item's offset
--   would point into the glue file, not the original source.
--
--   Requires ReaImGui. js_ReaScriptAPI is optional but strongly recommended: on
--   macOS it lets the window grab keyboard focus so you can type immediately.

local r = reaper

local VERSION   = "1.2.0"
local WIN_TITLE = "JG SRC Jump to Source Position  (v" .. VERSION .. ")"

if not r.ImGui_CreateContext then
  r.MB("This script requires ReaImGui.\n\n" ..
       "Install it via ReaPack:\n" ..
       "Extensions > ReaPack > Browse packages > \"ReaImGui\".",
       "Missing dependency", 0)
  return
end

local HAS_JS = (r.JS_Window_Find ~= nil) and (r.JS_Window_SetFocus ~= nil)

local SECTION  = "SRC_HUD"
local KEY_GUID = "track_guid"
local KEY_LAST = "last_file"
local RUN_FLAG = "jump_running"

-- ════════════════════════════════════════════════════════════════════════
--  Single-window guard: if a dialog is already open, just refocus it
-- ════════════════════════════════════════════════════════════════════════
if r.GetExtState(SECTION, RUN_FLAG) == "1" then
  local hwnd = HAS_JS and r.JS_Window_Find(WIN_TITLE, true) or nil
  if hwnd then r.JS_Window_SetFocus(hwnd); return end
  -- otherwise the flag is stale (previous instance died) → fall through and reopen
end

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

-- Apply the SRC look idempotently; only touches what is off (no flicker if clean).
local function applySRCStyle(tr)
  local changed = false
  r.PreventUIRefresh(1)
  local _, nm = r.GetTrackName(tr)
  if nm ~= "SRC" then
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", "SRC", true); changed = true
  end
  local wantColor = r.ColorToNative(255, 0, 0) | 0x1000000
  if r.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR") ~= wantColor then
    r.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", wantColor); changed = true
  end
  if r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") ~= 1 then  -- not already on top
    local sel = saveSel()
    r.SetOnlyTrackSelected(tr)
    r.ReorderSelectedTracks(0, 0)
    restoreSel(sel); changed = true
  end
  -- Pin to top (REAPER 7.46+). 40000 = "Track: Pin tracks to top of arrange view"
  -- — leaves other pins (incl. master) intact, unlike 40008. Guarded by B_TCPPIN
  -- so an already-pinned SRC is never toggled off; no-ops on pre-7.46 builds.
  local alreadyPinned = false
  pcall(function() alreadyPinned = r.GetMediaTrackInfo_Value(tr, "B_TCPPIN") == 1 end)
  if not alreadyPinned then
    local sel = saveSel()
    r.SetOnlyTrackSelected(tr)
    r.Main_OnCommand(40000, 0)
    restoreSel(sel); changed = true
  end
  r.PreventUIRefresh(-1)
  if changed then r.TrackList_AdjustWindows(false) end
  return changed
end

-- Resolve the SRC track: stored GUID (re-styled idempotently) or set up the
-- single selected track after a confirm. Returns track or nil.
local function setupSRC()
  local _, guid = r.GetProjExtState(0, SECTION, KEY_GUID)
  local tr = findTrackByGUID(guid)
  if tr then
    r.Undo_BeginBlock()
    applySRCStyle(tr)
    r.Undo_EndBlock("SRC Jump: re-apply SRC styling", -1)
    return tr
  end
  if r.CountSelectedTracks(0) ~= 1 then
    r.MB("No SRC track set up yet.\n\n" ..
         "Select exactly one source track and run the script again to set it up.",
         "SRC Jump", 0)
    return nil
  end
  tr = r.GetSelectedTrack(0, 0)
  local _, nm = r.GetTrackName(tr)
  if r.MB(("Set up the selected track \"%s\" as the SRC track?"):format(nm), "SRC Jump", 4) ~= 6 then
    return nil
  end
  r.Undo_BeginBlock()
  applySRCStyle(tr)
  r.SetProjExtState(0, SECTION, KEY_GUID, r.GetTrackGUID(tr))
  r.Undo_EndBlock("SRC Jump: set up track as SRC", -1)
  return tr
end

local srcTrack = setupSRC()
if not srcTrack then return end
local srcGUID = r.GetTrackGUID(srcTrack)

-- Claim the single-window slot and make sure it is released on close.
r.SetExtState(SECTION, RUN_FLAG, "1", false)
r.atexit(function() r.SetExtState(SECTION, RUN_FLAG, "0", false) end)

-- ════════════════════════════════════════════════════════════════════════
--  Position maths
--    src = offs + (cursor - pos) * rate ;  t = pos + (s - offs) / rate
--    hit:  offs <= s < offs + D_LENGTH * rate
-- ════════════════════════════════════════════════════════════════════════
local function basename(p)
  return (p or ""):match("[^/\\]+$") or (p or "")
end

local function fmt(t)
  if not t then return "—:—:—.———" end
  local neg = t < 0
  t = math.abs(t)
  local h = math.floor(t / 3600)
  local m = math.floor((t % 3600) / 60)
  local s = t % 60
  return string.format("%s%d:%02d:%06.3f", neg and "-" or "", h, m, s)
end

local function refPos()
  local ps = r.GetPlayState()
  if (ps & 1) ~= 0 then return r.GetPlayPosition() end
  return r.GetCursorPosition()
end

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

-- Every timeline position where source position `s` of `file` lands on SRC
-- (one per item whose source range contains `s`), sorted ascending in time.
local function timelinePositions(track, file, s)
  local list = {}
  for i = 0, r.CountTrackMediaItems(track) - 1 do
    local item = r.GetTrackMediaItem(track, i)
    local take = r.GetActiveTake(item)
    if takeSourceFile(take) == file then
      local pos  = r.GetMediaItemInfo_Value(item, "D_POSITION")
      local len  = r.GetMediaItemInfo_Value(item, "D_LENGTH")
      local offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
      local rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
      if s >= offs and s < offs + len * rate then
        list[#list + 1] = pos + (s - offs) / rate
      end
    end
  end
  table.sort(list)
  return list
end

local function nearestIndex(list, cursor)
  local bi, bd = 1, math.huge
  for i = 1, #list do
    local d = math.abs(list[i] - cursor)
    if d < bd then bi, bd = i, d end
  end
  return bi
end

local function distinctSourceFiles(track)
  local seen, list = {}, {}
  for i = 0, r.CountTrackMediaItems(track) - 1 do
    local f = takeSourceFile(r.GetActiveTake(r.GetTrackMediaItem(track, i)))
    if f ~= "" and not seen[f] then seen[f] = true; list[#list + 1] = f end
  end
  return list
end

local function resolveTargetFile(cursor)
  local f = srcUnderCursor(srcTrack, cursor)
  if f then return f end
  local _, lf = r.GetProjExtState(0, SECTION, KEY_LAST)
  if lf ~= "" then
    for _, x in ipairs(distinctSourceFiles(srcTrack)) do if x == lf then return lf end end
  end
  local list = distinctSourceFiles(srcTrack)
  if #list == 1 then return list[1] end
  return nil
end

-- Compact digit input: the last two digits are always seconds, everything before
-- is minutes (unbounded) — so 11637 = 116:37. EXCEPTION: exactly six digits are
-- read as HHMMSS, so hours need the full form (011637 = 1:16:37). Anything with
-- ":" / "." or fewer than four digits goes to REAPER's hh:mm:ss.xxx / seconds parser.
local function parseClock(str)
  str = (str or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if str:find("^%d+$") and #str >= 4 then
    if #str == 6 then            -- HHMMSS (hours need the full six digits)
      return tonumber(str:sub(1, 2)) * 3600
           + tonumber(str:sub(3, 4)) * 60
           + tonumber(str:sub(5, 6))
    end
    -- MMSS: last two = seconds, everything before = minutes
    return tonumber(str:sub(1, -3)) * 60 + tonumber(str:sub(-2))
  end
  return r.parse_timestr(str)
end

local function parseTarget(str, baseSrcPos)
  str = (str or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if str == "" then return nil, "empty" end
  local sign = str:sub(1, 1)
  if sign == "+" or sign == "-" then
    if not baseSrcPos then return nil, "relative needs the cursor over an SRC item" end
    return baseSrcPos + (sign == "+" and 1 or -1) * parseClock(str:sub(2))
  end
  return parseClock(str)
end

-- ════════════════════════════════════════════════════════════════════════
--  GUI
-- ════════════════════════════════════════════════════════════════════════
local ctx  = r.ImGui_CreateContext("JG SRC Jump")
local font = r.ImGui_CreateFont("sans-serif", 14)
r.ImGui_Attach(ctx, font)

local inputStr  = ""
local status    = nil
local needFocus = true
local done      = false
local frames    = 0
local cycleKey  = nil   -- identifies the current target (file@source-time)
local cycleList = nil   -- the matches captured when the cycle started
local cycleIdx  = 0     -- 1-based position in the cycle

local function doJump()
  local cursor = refPos()
  local file   = resolveTargetFile(cursor)
  if not file then
    status = "No target source: cursor over no SRC item and no single source file."
    return
  end
  local _, baseSrc = srcUnderCursor(srcTrack, cursor)
  local s, err = parseTarget(inputStr, baseSrc)
  if not s then status = "Invalid input (" .. (err or "?") .. ")."; return end

  local list = timelinePositions(srcTrack, file, s)
  if #list == 0 then
    status = ("%s not found in %s"):format(fmt(s), basename(file))
    return
  end

  local key = string.format("%s@%.3f", file, s)
  if key == cycleKey and cycleList and #cycleList == #list then
    cycleIdx = (cycleIdx % #list) + 1          -- same target again → next later (wraps)
  else
    cycleKey, cycleList = key, list            -- new target → start nearest the cursor
    cycleIdx = nearestIndex(list, cursor)
  end

  r.SetEditCurPos(list[cycleIdx], true, false)
  r.SetProjExtState(0, SECTION, KEY_LAST, file)

  if #list == 1 then
    done = true                                 -- single occurrence → jump and close
  else
    status = ("%s in %s — %d/%d   (Enter: next, Esc: close)")
             :format(fmt(s), basename(file), cycleIdx, #list)
  end
end

local function resetSRC()
  if r.ValidatePtr2(0, srcTrack, "MediaTrack*") then
    r.Undo_BeginBlock()
    pcall(function() r.SetMediaTrackInfo_Value(srcTrack, "B_TCPPIN", 0) end)
    r.SetMediaTrackInfo_Value(srcTrack, "I_CUSTOMCOLOR", 0)
    r.GetSetMediaTrackInfo_String(srcTrack, "P_NAME", "", true)
    r.Undo_EndBlock("SRC Jump: remove SRC marking", -1)
    r.TrackList_AdjustWindows(false)
  end
  r.SetProjExtState(0, SECTION, KEY_GUID, "")
  done = true   -- nothing to jump on anymore → close
end

local function draw()
  if not r.ValidatePtr2(0, srcTrack, "MediaTrack*") then
    srcTrack = findTrackByGUID(srcGUID)
    if not srcTrack then
      r.ImGui_TextColored(ctx, 0xFF6060FF, "SRC track no longer exists.")
      r.ImGui_Spacing(ctx)
      if r.ImGui_Button(ctx, "Close", 90, 0) then done = true end
      return
    end
  end

  local file = resolveTargetFile(refPos())
  if file then
    r.ImGui_TextColored(ctx, 0x80C0FFFF, "Target source: " .. basename(file))
  else
    r.ImGui_TextColored(ctx, 0xFF8080FF, "Target source: — (none detected)")
  end
  r.ImGui_Spacing(ctx)

  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Text(ctx, "Jump to:")
  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, 180)
  if needFocus then r.ImGui_SetKeyboardFocusHere(ctx) end
  local enter
  enter, inputStr = r.ImGui_InputText(ctx, "##jump", inputStr,
                                      r.ImGui_InputTextFlags_EnterReturnsTrue())
  if needFocus and r.ImGui_IsItemActive(ctx) then needFocus = false end

  r.ImGui_Spacing(ctx)
  r.ImGui_TextColored(ctx, 0x909090FF, "mmss            last 2 = sec, rest = min (11637 = 116:37)")
  r.ImGui_TextColored(ctx, 0x909090FF, "hhmmss          exactly 6 digits (011637 = 1:16:37)")
  r.ImGui_TextColored(ctx, 0x909090FF, "mm:ss.xxx / h:mm:ss.xxx   colon form")
  r.ImGui_TextColored(ctx, 0x909090FF, "123.4           plain seconds")
  r.ImGui_TextColored(ctx, 0x909090FF, "+val / -val     relative to source position")

  if status then
    r.ImGui_Spacing(ctx)
    r.ImGui_TextColored(ctx, 0xFFC040FF, status)
  end

  r.ImGui_Spacing(ctx)
  r.ImGui_Separator(ctx)
  if r.ImGui_Button(ctx, "OK", 90, 0) then enter = true end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Cancel", 90, 0) then done = true end
  r.ImGui_SameLine(ctx)
  if r.ImGui_SmallButton(ctx, "Reset SRC") then resetSRC() end

  if enter then doJump() end
  if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then done = true end
end

local function loop()
  r.ImGui_PushFont(ctx, font, 14)
  local vp = r.ImGui_GetMainViewport(ctx)
  local cx, cy = r.ImGui_Viewport_GetCenter(vp)
  r.ImGui_SetNextWindowPos(ctx, cx, cy, r.ImGui_Cond_Appearing(), 0.5, 0.5)
  if needFocus then r.ImGui_SetNextWindowFocus(ctx) end
  local flags = r.ImGui_WindowFlags_AlwaysAutoResize() |
                r.ImGui_WindowFlags_NoCollapse()
  local visible, open = r.ImGui_Begin(ctx, WIN_TITLE, true, flags)
  if visible then
    draw()
    r.ImGui_End(ctx)
  end
  r.ImGui_PopFont(ctx)

  -- Force OS keyboard focus until the input is active (macOS: ImGui's own focus
  -- call is not enough when launched from an action; js_ReaScriptAPI makes the
  -- native window key, found by its exact title).
  if needFocus and HAS_JS then
    local hwnd = r.JS_Window_Find(WIN_TITLE, true)
    if hwnd then r.JS_Window_SetFocus(hwnd) end
  end

  frames = frames + 1
  if frames > 60 then needFocus = false end
  if open and not done then r.defer(loop) end
end

loop()
