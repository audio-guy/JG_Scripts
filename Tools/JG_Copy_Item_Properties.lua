-- @description Copy item properties
-- @author JG
-- @version 2.2.0
-- @about
--   Copies the item structure (cuts / gaps) and any combination of item
--   properties from selected items on ONE reference track to selected items on the
--   other tracks. Unselected items are never modified.
--
--   Reference track
--     Pick it in the dialog. The default is the TOPMOST of the tracks that
--     have selected items.
--
--   Structure ("Cuts & gaps")
--     Selected target items are split at every edge of the reference items, and every
--     piece that falls into a gap of the reference is deleted. Optionally,
--     selected material outside the reference range is deleted as well.
--
--   Properties
--     Everything else is opt-in per checkbox: fades, item gain, take
--     volume/pan/phase, mute, colour, snap offset, notes, lock/loop/timebase,
--     group, take name, pitch/playrate, channel mode, the item FX chain and
--     the take envelopes (volume / pan / mute / pitch).
--
--     FX chains and take envelopes are copied through the item state chunk;
--     their FX/envelope GUIDs are regenerated so the copies stay independent.
--
--   The checkbox selection is remembered across sessions (ExtState).
--   Named presets store all checkboxes, independently of tracks and projects.
--   Click a preset to load it, then Apply to copy. Edit the checkboxes and
--   update the preset, or save a new one. Presets can be renamed and deleted.
--
--   Requires ReaImGui (ReaPack: Extensions > ReaPack > Browse packages).

local r = reaper

if not r.ImGui_CreateContext then
  r.MB("This script requires ReaImGui.\n\nInstall it via ReaPack:\nExtensions > ReaPack > Browse packages > search \"ReaImGui\".",
       "Missing dependency", 0)
  return
end

-- Keep the existing preference namespace across the rename.
local EXT = "JG_TransferItemProperties"
local TOL = 0.0001

-- ════════════════════════════════════════════════════════════════════════
--  Options
-- ════════════════════════════════════════════════════════════════════════
local OPTIONS = {
  { key = "cuts",     head = "Structure",
    label = "Cuts & gaps  (split at reference edges, delete gaps)", default = true },
  { key = "outside",  dep = "cuts", indent = true,
    label = "…also delete selected material outside the reference range",    default = true },

  { key = "fades",    head = "Item",
    label = "Fades  (length, shape, curvature, auto-crossfade)",     default = true },
  { key = "itemvol",  label = "Item volume (gain)",                  default = true },
  { key = "mute",     label = "Mute",                                default = true },
  { key = "color",    label = "Colour (item + take)",                default = false },
  { key = "snap",     label = "Snap offset",                         default = false },
  { key = "notes",    label = "Item notes",                          default = false },
  { key = "flags",    label = "Lock / loop source / timebase / play-all-takes", default = false },
  { key = "group",    label = "Group ID",                            default = false },

  { key = "takevol",  head = "Take",
    label = "Take volume / pan / pan law  (incl. phase invert)",     default = true },
  { key = "name",     label = "Take name",                           default = false },
  { key = "pitch",    label = "Pitch / playrate / preserve pitch",   default = false },
  { key = "chanmode", label = "Channel mode",                        default = false },
  { key = "fx",       label = "Item FX chain",                       default = true },
  { key = "env",      label = "Take envelopes (volume / pan / mute / pitch)", default = true },
}

local opt = {}

local function loadPrefs()
  for _, o in ipairs(OPTIONS) do
    local v = r.GetExtState(EXT, o.key)
    if v == "" then opt[o.key] = o.default else opt[o.key] = (v == "1") end
  end
end

local function savePrefs()
  for _, o in ipairs(OPTIONS) do
    r.SetExtState(EXT, o.key, opt[o.key] and "1" or "0", true)
  end
end

-- Presets use stable option keys, not checkbox order. A single ExtState value
-- avoids stale entries after rename/delete. Hex names keep the value single-line
-- and preserve UTF-8 and delimiter characters without evaluating stored code.
local presets, activePreset = {}, nil

local function snapshotOptions()
  local values = {}
  for _, o in ipairs(OPTIONS) do values[o.key] = opt[o.key] == true end
  return values
end

local function presetModified()
  if not activePreset then return false end
  for _, o in ipairs(OPTIONS) do
    if opt[o.key] ~= activePreset.values[o.key] then return true end
  end
  return false
end

local function savePresets()
  local records = { "v1" }
  for _, preset in ipairs(presets) do
    local name = preset.name:gsub(".", function(c) return string.format("%02X", c:byte()) end)
    local fields = {}
    for _, o in ipairs(OPTIONS) do
      fields[#fields+1] = o.key .. "=" .. (preset.values[o.key] and "1" or "0")
    end
    records[#records+1] = name .. "|" .. table.concat(fields, ",")
  end
  r.SetExtState(EXT, "presets", table.concat(records, ";"), true)
  r.SetExtState(EXT, "active_preset", activePreset and activePreset.name or "", true)
end

local function validPresetName(name, except)
  name = name:match("^%s*(.-)%s*$")
  if name == "" then return nil, "Enter a preset name." end
  if name:find("%c") or name:find("##", 1, true) then
    return nil, "Names cannot contain control characters or ##."
  end
  for _, preset in ipairs(presets) do
    if preset ~= except and preset.name:lower() == name:lower() then
      return nil, "That name already exists. Choose another name or use Update preset."
    end
  end
  return name
end

local function loadPresets()
  presets, activePreset = {}, nil
  local stored = r.GetExtState(EXT, "presets")
  if stored ~= "v1" and stored:sub(1, 3) ~= "v1;" then return end
  local active = r.GetExtState(EXT, "active_preset")
  for record in stored:sub(4):gmatch("[^;]+") do
    local encoded, fields = record:match("^(%x+)|(.+)$")
    if encoded and #encoded % 2 == 0 then
      local name = encoded:gsub("%x%x", function(hex) return string.char(tonumber(hex, 16)) end)
      name = validPresetName(name)
      if name then
        local values = {}
        -- New options remain off in older presets until explicitly enabled.
        for _, o in ipairs(OPTIONS) do values[o.key] = false end
        for key, value in fields:gmatch("([%w_]+)=([01])") do
          if values[key] ~= nil then values[key] = value == "1" end
        end
        local preset = { name = name, values = values }
        presets[#presets+1] = preset
        if name == active then activePreset = preset end
      end
    end
  end
end

local function selectPreset(preset)
  activePreset = preset
  for _, o in ipairs(OPTIONS) do opt[o.key] = preset.values[o.key] end
  savePrefs()
  r.SetExtState(EXT, "active_preset", preset.name, true)
end

local function createPreset(name)
  local checked, err = validPresetName(name)
  if not checked then return nil, err end
  activePreset = { name = checked, values = snapshotOptions() }
  presets[#presets+1] = activePreset
  savePresets()
  return activePreset
end

local function updatePreset()
  if not activePreset then return end
  activePreset.values = snapshotOptions()
  savePresets()
end

local function renamePreset(name)
  if not activePreset then return nil, "Select a preset first." end
  local checked, err = validPresetName(name, activePreset)
  if not checked then return nil, err end
  activePreset.name = checked
  savePresets()
  return activePreset
end

local function deletePreset()
  if not activePreset then return end
  for i, preset in ipairs(presets) do
    if preset == activePreset then table.remove(presets, i); break end
  end
  activePreset = nil
  savePresets()
end

-- ════════════════════════════════════════════════════════════════════════
--  Property tables
-- ════════════════════════════════════════════════════════════════════════
local ITEM_NUM = {
  fades   = { "D_FADEINLEN", "D_FADEOUTLEN", "D_FADEINDIR", "D_FADEOUTDIR",
              "C_FADEINSHAPE", "C_FADEOUTSHAPE",
              "D_FADEINLEN_AUTO", "D_FADEOUTLEN_AUTO" },
  itemvol = { "D_VOL" },
  mute    = { "B_MUTE" },
  color   = { "I_CUSTOMCOLOR" },
  snap    = { "D_SNAPOFFSET" },
  flags   = { "C_LOCK", "B_LOOPSRC", "C_BEATATTACHMODE", "B_ALLTAKESPLAY" },
  group   = { "I_GROUPID" },
}

local TAKE_NUM = {
  takevol  = { "D_VOL", "D_PAN", "D_PANLAW" },
  pitch    = { "D_PITCH", "B_PPITCH", "D_PLAYRATE" },
  chanmode = { "I_CHANMODE" },
  color    = { "I_CUSTOMCOLOR" },
}

local ITEM_STR = { notes = "P_NOTES" }
local TAKE_STR = { name  = "P_NAME"  }

local ENV_BLOCKS = { "VOLENV", "VOLENV2", "PANENV", "PANENV2", "MUTEENV", "PITCHENV" }

-- ════════════════════════════════════════════════════════════════════════
--  Item state chunk surgery (FX chain + take envelopes)
--
--  Reaper chunks nest by whole lines: a line starting with "<" opens a block,
--  a line that is only ">" closes it. Angle brackets INSIDE a line (VST
--  headers) are never structural, so line-anchored matching is safe.
-- ════════════════════════════════════════════════════════════════════════
local function splitLines(s)
  local t = {}
  for line in s:gmatch("[^\r\n]+") do t[#t+1] = line end
  return t
end

-- Returns header line, list of depth-1 nodes, footer line.
-- node = { kind = "line", key = <first token>, text = ... }
--       | { kind = "block", name = <block name>, lines = { ... } }
local function parseItemChunk(chunk)
  local lines = splitLines(chunk)
  if #lines < 2 or not lines[1]:match("^%s*<ITEM") then return nil end
  local nodes, i, last = {}, 2, #lines
  while i < last do
    local name = lines[i]:match("^%s*<(%S+)")
    if name then
      local depth, blk = 0, {}
      repeat
        local l = lines[i]
        blk[#blk+1] = l
        if l:match("^%s*<") then depth = depth + 1
        elseif l:match("^%s*>%s*$") then depth = depth - 1 end
        i = i + 1
      until depth == 0 or i > last
      nodes[#nodes+1] = { kind = "block", name = name, lines = blk }
    else
      nodes[#nodes+1] = { kind = "line", key = lines[i]:match("^%s*(%S+)") or "", text = lines[i] }
      i = i + 1
    end
  end
  return lines[1], nodes, lines[last]
end

-- Takes are separated by a bare "TAKE" line; the first take shares its section
-- with the item-level lines (POSITION, LENGTH, FADEIN, …).
local function takeSections(nodes)
  local ranges, from = {}, 1
  for i, n in ipairs(nodes) do
    if n.kind == "line" and n.key == "TAKE" and i > 1 then
      ranges[#ranges+1] = { from, i - 1 }
      from = i
    end
  end
  ranges[#ranges+1] = { from, #nodes }
  return ranges
end

-- Copy a block, giving every FX / envelope a fresh GUID so source and target
-- do not share identities.
local function cloneBlock(node)
  local out = {}
  for i, l in ipairs(node.lines) do
    local indent, key = l:match("^(%s*)(FXID)%s+{.-}%s*$")
    if not key then indent, key = l:match("^(%s*)(EGUID)%s+{.-}%s*$") end
    if key then
      out[i] = indent .. key .. " " .. r.genGuid("")
    else
      out[i] = l
    end
  end
  return { kind = "block", name = node.name, lines = out }
end

-- Replace the named depth-1 blocks of dstChunk with those of srcChunk,
-- take section by take section. Returns nil when nothing changed.
local function mergeBlocks(dstChunk, srcChunk, names)
  local dHead, dNodes, dFoot = parseItemChunk(dstChunk)
  local _,     sNodes        = parseItemChunk(srcChunk)
  if not dNodes or not sNodes then return nil end

  local dSec, sSec = takeSections(dNodes), takeSections(sNodes)
  local out, changed = {}, false

  for k, rng in ipairs(dSec) do
    local sec = {}
    for i = rng[1], rng[2] do
      local n = dNodes[i]
      if n.kind == "block" and names[n.name] then changed = true else sec[#sec+1] = n end
    end

    local sr = sSec[k]
    if sr then
      local add = {}
      for i = sr[1], sr[2] do
        local n = sNodes[i]
        if n.kind == "block" and names[n.name] then add[#add+1] = cloneBlock(n) end
      end
      if #add > 0 then
        changed = true
        -- Reaper writes TAKEFX / take envelopes ahead of <SOURCE>; keep that order.
        local at = #sec + 1
        for i = 1, #sec do
          if sec[i].kind == "block" and sec[i].name == "SOURCE" then at = i; break end
        end
        for j = #add, 1, -1 do table.insert(sec, at, add[j]) end
      end
    end

    for _, n in ipairs(sec) do out[#out+1] = n end
  end

  if not changed then return nil end

  local buf = { dHead }
  for _, n in ipairs(out) do
    if n.kind == "block" then
      for _, l in ipairs(n.lines) do buf[#buf+1] = l end
    else
      buf[#buf+1] = n.text
    end
  end
  buf[#buf+1] = dFoot
  return table.concat(buf, "\n") .. "\n"
end

-- ════════════════════════════════════════════════════════════════════════
--  Property copy
-- ════════════════════════════════════════════════════════════════════════
local function copyProps(dst, src, srcChunks)
  -- 1. Chunk-based parts first — SetItemStateChunk invalidates take pointers.
  local names = {}
  if opt.fx  then names.TAKEFX = true end
  if opt.env then for _, n in ipairs(ENV_BLOCKS) do names[n] = true end end
  if next(names) then
    local sc = srcChunks[src]
    if sc == nil then
      local ok
      ok, sc = r.GetItemStateChunk(src, "", false)
      if not ok then sc = false end
      srcChunks[src] = sc
    end
    local okS = sc and true or false
    local okD, dc = r.GetItemStateChunk(dst, "", false)
    if okS and okD then
      local merged = mergeBlocks(dc, sc, names)
      if merged then r.SetItemStateChunk(dst, merged, false) end
    end
  end

  -- 2. Item level
  for key, params in pairs(ITEM_NUM) do
    if opt[key] then
      for _, p in ipairs(params) do
        r.SetMediaItemInfo_Value(dst, p, r.GetMediaItemInfo_Value(src, p))
      end
    end
  end
  for key, p in pairs(ITEM_STR) do
    if opt[key] then
      local ok, v = r.GetSetMediaItemInfo_String(src, p, "", false)
      if ok then r.GetSetMediaItemInfo_String(dst, p, v, true) end
    end
  end

  -- 3. Active take level
  local sTake = r.GetActiveTake(src)
  local dTake = r.GetActiveTake(dst)
  if sTake and dTake then
    for key, params in pairs(TAKE_NUM) do
      if opt[key] then
        for _, p in ipairs(params) do
          r.SetMediaItemTakeInfo_Value(dTake, p, r.GetMediaItemTakeInfo_Value(sTake, p))
        end
      end
    end
    for key, p in pairs(TAKE_STR) do
      if opt[key] then
        local ok, v = r.GetSetMediaItemTakeInfo_String(sTake, p, "", false)
        if ok then r.GetSetMediaItemTakeInfo_String(dTake, p, v, true) end
      end
    end
  end
end

-- ════════════════════════════════════════════════════════════════════════
--  Selection model
-- ════════════════════════════════════════════════════════════════════════
local function collectSelection()
  local map, list = {}, {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    local item  = r.GetSelectedMediaItem(0, i)
    local track = r.GetMediaItem_Track(item)
    local guid  = r.GetTrackGUID(track)
    local e = map[guid]
    if not e then
      local _, nm = r.GetTrackName(track)
      e = {
        track = track, guid = guid, name = nm,
        num   = math.floor(r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")),
        items = {},
      }
      map[guid] = e
      list[#list+1] = e
    end
    e.items[#e.items+1] = {
      item = item,
      pos  = r.GetMediaItemInfo_Value(item, "D_POSITION"),
      len  = r.GetMediaItemInfo_Value(item, "D_LENGTH"),
    }
  end
  table.sort(list, function(a, b) return a.num < b.num end)
  for _, e in ipairs(list) do
    table.sort(e.items, function(a, b) return a.pos < b.pos end)
  end
  return list
end

-- ════════════════════════════════════════════════════════════════════════
--  Main operation
-- ════════════════════════════════════════════════════════════════════════
local function run(tracks, refIdx)
  local src = tracks[refIdx]
  if not src or #tracks < 2 then return "Need selected items on at least 2 tracks." end

  local keep = {}
  for _, it in ipairs(src.items) do keep[#keep+1] = { s = it.pos, e = it.pos + it.len } end
  local rangeStart, rangeEnd = keep[1].s, keep[#keep].e
  for _, iv in ipairs(keep) do
    if iv.e > rangeEnd then rangeEnd = iv.e end
  end

  local splits, seen = {}, {}
  for _, iv in ipairs(keep) do
    for _, p in ipairs({ iv.s, iv.e }) do
      if not seen[p] then seen[p] = true; splits[#splits+1] = p end
    end
  end
  table.sort(splits)

  local function inKeep(pos)
    for _, iv in ipairs(keep) do
      if pos >= iv.s - TOL and pos < iv.e - TOL then return true end
    end
    return false
  end

  -- Source item for a target piece: same start, else the one covering its middle.
  local function srcFor(pos, len)
    for _, si in ipairs(src.items) do
      if math.abs(pos - si.pos) < TOL then return si.item end
    end
    local mid = pos + len / 2
    for _, si in ipairs(src.items) do
      if mid >= si.pos - TOL and mid < si.pos + si.len - TOL then return si.item end
    end
    return nil
  end

  local anyProp = false
  for _, o in ipairs(OPTIONS) do
    if o.key ~= "cuts" and o.key ~= "outside" and opt[o.key] then anyProp = true; break end
  end

  local touched, removed = 0, 0
  local srcChunks = {}

  r.PreventUIRefresh(1)
  r.Undo_BeginBlock()

  for ti = 1, #tracks do
    if ti ~= refIdx then
      local tgt = tracks[ti]
      -- Only the selection captured for this operation and its split descendants
      -- may be changed. Never expand the scope to all items on the track.
      local pieces = {}
      for _, it in ipairs(tgt.items) do
        pieces[#pieces+1] = { item = it.item, pos = it.pos, len = it.len }
      end

      if opt.cuts then
        -- Split at every reference edge. Splits are sorted, and SplitMediaItem
        -- hands back the right-hand piece, so each item is walked exactly once.
        local originals = #pieces
        for i = 1, originals do
          local it = pieces[i]
          local cur, pos, len = it.item, it.pos, it.len
          for _, sp in ipairs(splits) do
            if sp > pos + TOL and sp < pos + len - TOL then
              local right = r.SplitMediaItem(cur, sp)
              if right then
                it.len = sp - pos
                len = pos + len - sp
                pos = sp
                cur = right
                it = { item = right, pos = pos, len = len }
                pieces[#pieces+1] = it
              end
            end
          end
        end
        -- Delete gap pieces (and, optionally, everything outside the range).
        local doomed, kept = {}, {}
        for _, it in ipairs(pieces) do
          local mid = it.pos + it.len / 2
          local outside = mid < rangeStart - TOL or mid >= rangeEnd - TOL
          if (outside and opt.outside) or (not outside and not inKeep(mid)) then
            doomed[#doomed+1] = it.item
          else
            kept[#kept+1] = it
          end
        end
        pieces = kept
        for _, it in ipairs(doomed) do
          r.DeleteTrackMediaItem(tgt.track, it)
          removed = removed + 1
        end
      end

      if anyProp then
        for _, it in ipairs(pieces) do
          local mid = it.pos + it.len / 2
          if mid >= rangeStart - TOL and mid < rangeEnd - TOL then
            local s = srcFor(it.pos, it.len)
            if s then
              copyProps(it.item, s, srcChunks)
              touched = touched + 1
            end
          end
        end
      end
    end
  end

  r.Undo_EndBlock("Copy item properties", -1)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()

  return string.format("Done — %d item(s) updated, %d deleted, on %d target track(s).",
                       touched, removed, #tracks - 1)
end

-- ════════════════════════════════════════════════════════════════════════
--  GUI
-- ════════════════════════════════════════════════════════════════════════
loadPrefs()
loadPresets()

local tracks = collectSelection()
if #tracks < 2 then
  r.MB("Select items on at least 2 tracks.", "Copy Item Properties", 0)
  return
end

local refGuid = tracks[1].guid          -- default: topmost selected track
local status  = "Pick the reference track, then Apply."
local dirty   = false
local presetName = activePreset and activePreset.name or ""
local presetMessage = ""
local confirmDelete = false

local ctx  = r.ImGui_CreateContext("JG Copy Item Properties")
local font = r.ImGui_CreateFont("sans-serif", 14)
r.ImGui_Attach(ctx, font)

local function refIndex()
  for i, t in ipairs(tracks) do
    if t.guid == refGuid then return i end
  end
  return nil
end

-- The item selection can change while the dialog is open; re-read it so the
-- track list stays live and no stale item pointers survive an edit made behind
-- our back. Gated on the project change counter so a huge selection is not
-- walked on every single frame.
local lastChange, lastCount = -1, -1

local function refresh(force)
  local c, n = r.GetProjectStateChangeCount(0), r.CountSelectedMediaItems(0)
  if not force and c == lastChange and n == lastCount then return end
  lastChange, lastCount = c, n
  tracks = collectSelection()
  if not refIndex() then refGuid = tracks[1] and tracks[1].guid or nil end
end

local function drawPresets()
  r.ImGui_Text(ctx, "Presets")
  if #presets == 0 then
    r.ImGui_TextWrapped(ctx, "Choose options below, enter a name, then Save as new.")
  else
    if r.ImGui_BeginChild(ctx, "##presets", 0, 78) then
      for i, preset in ipairs(presets) do
        if r.ImGui_Selectable(ctx, preset.name .. "###preset" .. i, preset == activePreset) then
          selectPreset(preset)
          presetName, presetMessage, confirmDelete = preset.name, "Preset loaded. Click Apply to copy.", false
        end
      end
    end
    r.ImGui_EndChild(ctx)
  end
  if activePreset and presetModified() then
    r.ImGui_TextWrapped(ctx, "Modified: update the preset or save as new to keep these changes.")
  end
  local changed, name = r.ImGui_InputText(ctx, "Preset name", presetName)
  if changed then presetName = name; presetMessage = ""; confirmDelete = false end
  if r.ImGui_Button(ctx, "Save as new") then
    local preset, err = createPreset(presetName)
    presetMessage = err or "New preset saved."
    if preset then presetName = preset.name end
    confirmDelete = false
  end
  r.ImGui_SameLine(ctx)
  if not activePreset then r.ImGui_BeginDisabled(ctx, true) end
  if r.ImGui_Button(ctx, "Update preset") then
    updatePreset()
    presetMessage, confirmDelete = "Preset options updated.", false
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Rename") then
    local preset, err = renamePreset(presetName)
    presetMessage = err or "Preset renamed."
    if preset then presetName = preset.name end
    confirmDelete = false
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Delete") then confirmDelete = true end
  if not activePreset then r.ImGui_EndDisabled(ctx) end
  if confirmDelete and activePreset then
    r.ImGui_TextWrapped(ctx, 'Delete preset "' .. activePreset.name .. '"?')
    if r.ImGui_Button(ctx, "Delete preset") then
      deletePreset()
      presetName, presetMessage, confirmDelete = "", "Preset deleted. Current options kept.", false
    end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Cancel") then confirmDelete = false end
  end
  if presetMessage ~= "" then r.ImGui_TextWrapped(ctx, presetMessage) end
  r.ImGui_Separator(ctx)
end

local function drawGUI()
  r.ImGui_TextWrapped(ctx,
    "Copies structure and enabled properties from selected reference items " ..
    "to selected items on the other tracks. Unselected items stay unchanged.")
  r.ImGui_Separator(ctx)

  r.ImGui_Text(ctx, "Reference track:")
  if #tracks < 2 then
    r.ImGui_TextWrapped(ctx, "Select items on at least 2 tracks.")
  end
  for i, t in ipairs(tracks) do
    local label = string.format("%d  %s  (%d item%s)###ref%d",
      t.num, (t.name ~= "" and t.name or "(unnamed)"), #t.items,
      #t.items == 1 and "" or "s", i)
    if r.ImGui_RadioButton(ctx, label, t.guid == refGuid) then refGuid = t.guid end
  end

  r.ImGui_Separator(ctx)
  drawPresets()
  r.ImGui_Text(ctx, "Copy:")

  for _, o in ipairs(OPTIONS) do
    if o.head then
      r.ImGui_Spacing(ctx)
      r.ImGui_TextDisabled(ctx, o.head)
    end
    local disabled = o.dep and not opt[o.dep]
    if disabled then r.ImGui_BeginDisabled(ctx, true) end
    if o.indent then r.ImGui_Indent(ctx, 20) end
    local chg, v = r.ImGui_Checkbox(ctx, o.label, opt[o.key])
    if chg then opt[o.key] = v; dirty = true end
    if o.indent then r.ImGui_Unindent(ctx, 20) end
    if disabled then r.ImGui_EndDisabled(ctx) end
  end

  r.ImGui_Spacing(ctx)
  if r.ImGui_Button(ctx, "All", 60, 22) then
    for _, o in ipairs(OPTIONS) do opt[o.key] = true end
    dirty = true
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "None", 60, 22) then
    for _, o in ipairs(OPTIONS) do opt[o.key] = false end
    dirty = true
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Defaults", 80, 22) then
    for _, o in ipairs(OPTIONS) do opt[o.key] = o.default end
    dirty = true
  end

  r.ImGui_Separator(ctx)
  r.ImGui_TextWrapped(ctx, status)
end

local applyNow, closeNow = false, false

local function loop()
  refresh()
  r.ImGui_PushFont(ctx, font, 14)
  r.ImGui_SetNextWindowSize(ctx, 560, 850, r.ImGui_Cond_FirstUseEver())
  local flags = r.ImGui_WindowFlags_NoCollapse()
  local visible, open = r.ImGui_Begin(ctx, "JG Copy Item Properties", true, flags)
  if visible then
    drawGUI()
    r.ImGui_Spacing(ctx)
    local ready = #tracks >= 2 and refIndex() ~= nil
    if not ready then r.ImGui_BeginDisabled(ctx, true) end
    if r.ImGui_Button(ctx, "Apply", 120, 28) then applyNow = true end
    if not ready then r.ImGui_EndDisabled(ctx) end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Close", 100, 28) then closeNow = true end
    r.ImGui_End(ctx)
  end
  r.ImGui_PopFont(ctx)

  if applyNow then
    applyNow = false
    savePrefs()
    dirty  = false
    status = run(tracks, refIndex())
    refresh(true)                        -- items changed under us
  end

  if dirty then savePrefs(); dirty = false end
  if open and not closeNow then r.defer(loop) end
end

r.atexit(savePrefs)
loop()
