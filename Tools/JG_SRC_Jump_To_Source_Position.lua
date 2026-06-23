-- @description SRC Jump To Source Position (keyboard-first jump dialog, edit-proof)
-- @author JG
-- @version 1.0.0
-- @about
--   A small "Jump to" dialog (à la REAPER's native action 40069) that jumps the
--   edit cursor to a SOURCE-file position on the SRC track. Unlike 40069 — which
--   is timeline-absolute — the target is computed from the SRC item's CURRENT
--   position + start offset, so the same source time keeps landing on the same
--   content after ripple cuts and moves.
--
--   Meant to be bound to a shortcut: the input field is auto-focused, so you can
--   type immediately; Enter jumps and closes the window, Esc cancels. On a
--   not-found time the window stays open with a message so you can correct it.
--
--   Accepted input (the source-meaningful subset of 40069):
--     mm:ss.xxx       minutes:seconds.fraction
--     h:mm:ss.xxx     hours:minutes:seconds.fraction
--     123.4           plain seconds
--     +val / -val     relative to the current source position under the cursor
--   Marker/region/measure/track-item syntaxes of 40069 are timeline concepts and
--   do not map to a source position, so they are intentionally not supported.
--
--   Target file = the SRC source under the edit/play cursor; if the cursor sits
--   in a gap, the last file seen (shared with the HUD via project ExtState) or —
--   if the SRC track holds a single source — that one. Requires an SRC track set
--   up by JG_SRC_Source_Position_HUD, and ReaImGui.

local r = reaper

if not r.ImGui_CreateContext then
  r.MB("Dieses Script benötigt ReaImGui.\n\n" ..
       "Installiere es über ReaPack:\n" ..
       "Extensions > ReaPack > Browse packages > \"ReaImGui\".",
       "Fehlende Abhängigkeit", 0)
  return
end

local SECTION   = "SRC_HUD"
local KEY_GUID  = "track_guid"
local KEY_LAST  = "last_file"

-- ════════════════════════════════════════════════════════════════════════
--  Shared helpers (same maths as the HUD)
-- ════════════════════════════════════════════════════════════════════════
local function findTrackByGUID(guid)
  if not guid or guid == "" then return nil end
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    if r.GetTrackGUID(tr) == guid then return tr end
  end
  return nil
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

-- file + source position of the SRC item under a project-time cursor
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

-- timeline time of source position `s` in `file` on SRC; nearest to `cursor` on overlap
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

local function distinctSourceFiles(track)
  local seen, list = {}, {}
  for i = 0, r.CountTrackMediaItems(track) - 1 do
    local f = takeSourceFile(r.GetActiveTake(r.GetTrackMediaItem(track, i)))
    if f ~= "" and not seen[f] then seen[f] = true; list[#list + 1] = f end
  end
  return list
end

-- ════════════════════════════════════════════════════════════════════════
--  Resolve the SRC track and the target file
-- ════════════════════════════════════════════════════════════════════════
local _, guid = r.GetProjExtState(0, SECTION, KEY_GUID)
local srcTrack = findTrackByGUID(guid)
if not srcTrack then
  r.MB("Keine SRC-Spur eingerichtet.\n\n" ..
       "Starte zuerst das HUD (JG_SRC_Source_Position_HUD) und richte eine SRC-Spur ein.",
       "SRC Jump", 0)
  return
end

local function resolveTargetFile(cursor)
  local f = srcUnderCursor(srcTrack, cursor)          -- 1) under the cursor
  if f then return f end
  local _, lf = r.GetProjExtState(0, SECTION, KEY_LAST) -- 2) last seen (shared w/ HUD)
  if lf ~= "" then
    for _, x in ipairs(distinctSourceFiles(srcTrack)) do if x == lf then return lf end end
  end
  local list = distinctSourceFiles(srcTrack)            -- 3) the only source on SRC
  if #list == 1 then return list[1] end
  return nil
end

-- "+5", "-1:02", "2:11:26.310", "90.5" → source position (seconds)
local function parseTarget(str, baseSrcPos)
  str = (str or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if str == "" then return nil, "leer" end
  local sign = str:sub(1, 1)
  if sign == "+" or sign == "-" then
    if not baseSrcPos then return nil, "relativ braucht Cursor über einem SRC-Item" end
    local delta = r.parse_timestr(str:sub(2))
    return baseSrcPos + (sign == "+" and delta or -delta)
  end
  return r.parse_timestr(str)
end

-- ════════════════════════════════════════════════════════════════════════
--  GUI — keyboard-first, auto-focused, Enter jumps + closes, Esc cancels
-- ════════════════════════════════════════════════════════════════════════
local ctx  = r.ImGui_CreateContext("JG SRC Jump")
local font = r.ImGui_CreateFont("sans-serif", 14)
r.ImGui_Attach(ctx, font)

local inputStr  = ""
local status    = nil
local needFocus = true
local done      = false

local function doJump()
  local cursor = refPos()
  local file   = resolveTargetFile(cursor)
  if not file then
    status = "Keine Zieldatei: Cursor über kein SRC-Item und kein eindeutiges Quellfile."
    return
  end
  local _, baseSrc = srcUnderCursor(srcTrack, cursor)
  local s, err = parseTarget(inputStr, baseSrc)
  if not s then status = "Ungültige Eingabe (" .. (err or "?") .. ")."; return end
  local t = timelineForSource(srcTrack, file, s, cursor)
  if t then
    r.SetEditCurPos(t, true, false)
    r.SetProjExtState(0, SECTION, KEY_LAST, file)     -- remember for next time
    done = true                                        -- success → close
  else
    status = ("%s nicht in %s"):format(fmt(s), basename(file))
  end
end

local function draw()
  -- live target-file hint, so the user knows where the jump will land
  local file = resolveTargetFile(refPos())
  if file then
    r.ImGui_TextColored(ctx, 0x80C0FFFF, "Ziel-Quelle: " .. basename(file))
  else
    r.ImGui_TextColored(ctx, 0xFF8080FF, "Ziel-Quelle: — (keine erkannt)")
  end
  r.ImGui_Spacing(ctx)

  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Text(ctx, "Springe zu:")
  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, 180)
  if needFocus then r.ImGui_SetKeyboardFocusHere(ctx) end
  local enter
  enter, inputStr = r.ImGui_InputText(ctx, "##jump", inputStr,
                                      r.ImGui_InputTextFlags_EnterReturnsTrue())
  if needFocus and r.ImGui_IsItemActive(ctx) then needFocus = false end

  r.ImGui_Spacing(ctx)
  r.ImGui_TextColored(ctx, 0x909090FF, "mm:ss.xxx     Minuten:Sekunden")
  r.ImGui_TextColored(ctx, 0x909090FF, "h:mm:ss.xxx   Stunden:Minuten:Sekunden")
  r.ImGui_TextColored(ctx, 0x909090FF, "123.4         reine Sekunden")
  r.ImGui_TextColored(ctx, 0x909090FF, "+val / -val   relativ zur Quellposition")

  if status then
    r.ImGui_Spacing(ctx)
    r.ImGui_TextColored(ctx, 0xFFC040FF, status)
  end

  r.ImGui_Spacing(ctx)
  r.ImGui_Separator(ctx)
  if r.ImGui_Button(ctx, "OK", 90, 0) then enter = true end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Cancel", 90, 0) then done = true end

  if enter then doJump() end
  if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then done = true end
end

local function loop()
  r.ImGui_PushFont(ctx, font, 14)
  local vp = r.ImGui_GetMainViewport(ctx)
  local cx, cy = r.ImGui_Viewport_GetCenter(vp)
  r.ImGui_SetNextWindowPos(ctx, cx, cy, r.ImGui_Cond_Appearing(), 0.5, 0.5)
  r.ImGui_SetNextWindowFocus(ctx)
  local flags = r.ImGui_WindowFlags_AlwaysAutoResize() |
                r.ImGui_WindowFlags_NoCollapse() |
                r.ImGui_WindowFlags_TopMost()
  local visible, open = r.ImGui_Begin(ctx, "Springe zu Quellposition", true, flags)
  if visible then
    draw()
    r.ImGui_End(ctx)
  end
  r.ImGui_PopFont(ctx)

  if open and not done then r.defer(loop) end
end

loop()
