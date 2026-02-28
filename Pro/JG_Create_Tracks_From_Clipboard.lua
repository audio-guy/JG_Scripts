-- @description Create named tracks from clipboard (inc. I/O patch)
-- @author Julius Gass
-- @version 1.0.0
-- @about
--   Creates named tracks from clipboard text (one track name per line).
--   Automatically detects stereo pairs and lets you confirm via GUI.
--   Optionally sets up 1:1 hardware routing for Virtual Soundcheck.
--   Requires SWS Extension and ReaImGui.

-- ─── Dependency Checks ───────────────────────────────────────────────────────
if not reaper.CF_GetClipboard then
  reaper.ShowMessageBox("This script requires the SWS Extension!", "Error", 0)
  return
end
if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox("This script requires the ReaImGui Extension!\nInstall via ReaPack: ReaTeam Extensions.", "Error", 0)
  return
end

-- ─── Stereo Pair Patterns ────────────────────────────────────────────────────
local STEREO_PATTERNS = {
  { "^(.-)%s+[Ll]$",                  "^(.-)%s+[Rr]$"                       },
  { "^(.-)%s*_[Ll]$",                 "^(.-)%s*_[Rr]$"                      },
  { "^(.-)%s+[Ll][Ee][Ff][Tt]$",      "^(.-)%s+[Rr][Ii][Gg][Hh][Tt]$"      },
  { "^(.-)%s*_[Ll][Ee][Ff][Tt]$",     "^(.-)%s*_[Rr][Ii][Gg][Hh][Tt]$"     },
  { "^(.-)%s+[Ll][Ii][Nn][Kk][Ss]$",  "^(.-)%s+[Rr][Ee][Cc][Hh][Tt][Ss]$"  },
  { "^(.-)%s*_[Ll][Ii][Nn][Kk][Ss]$", "^(.-)%s*_[Rr][Ee][Cc][Hh][Tt][Ss]$" },
  { "^(.-)%s+[Ll][Oo]$",              "^(.-)%s+[Hh][Ii]$"                   },
  { "^(.-)%s*_[Ll][Oo]$",             "^(.-)%s*_[Hh][Ii]$"                  },
  { "^(.-)%s+[Ll][Oo][Ww]$",          "^(.-)%s+[Hh][Ii][Gg][Hh]$"          },
  { "^(.-)%s*_[Ll][Oo][Ww]$",         "^(.-)%s*_[Hh][Ii][Gg][Hh]$"         },
  { "^(.-)%s+[Aa]$",                  "^(.-)%s+[Bb]$"                       },
  { "^(.-)%s*_[Aa]$",                 "^(.-)%s*_[Bb]$"                      },
  { "^(.-)%s+[Xx]$",                  "^(.-)%s+[Yy]$"                       },
  { "^(.-)%s*_[Xx]$",                 "^(.-)%s*_[Yy]$"                      },
  { "^(.-)%s+1$",                     "^(.-)%s+2$"                          },
  { "^(.-)%s*_1$",                    "^(.-)%s*_2$"                         },
}

-- ─── Helper: Set HW Output via Chunk ────────────────────────────────────────
local function set_hw_output_via_chunk(tr, hw_idx, is_stereo)
  local ok, chunk = reaper.GetTrackStateChunk(tr, "", false)
  if not ok then return end
  local dst = is_stereo and hw_idx or (1024 + hw_idx)
  local src = is_stereo and 0 or 1024
  local hwout = string.format('HWOUT %d %d 1 0 0 0 ""', dst, src)
  local pos = chunk:find(">%s*$")
  if pos then
    chunk = chunk:sub(1, pos - 1) .. hwout .. "\n>"
  end
  reaper.SetTrackStateChunk(tr, chunk, false)
end

-- ─── Helper: Clear Master HW Outputs ────────────────────────────────────────
local function clear_master_hw_outputs()
  local master = reaper.GetMasterTrack(0)
  for j = reaper.GetTrackNumSends(master, -1) - 1, 0, -1 do
    reaper.RemoveTrackSend(master, -1, j)
  end
  local ok, chunk = reaper.GetTrackStateChunk(master, "", false)
  if ok then
    chunk = chunk:gsub('\nHWOUT [^\n]+', '')
    reaper.SetTrackStateChunk(master, chunk, false)
  end
end

-- ─── Step 1: Get Clipboard & User Inputs ────────────────────────────────────
local text_input = reaper.CF_GetClipboard("")
if not text_input or text_input == "" then
  reaper.ShowMessageBox("Clipboard is empty!", "Error", 0)
  return
end

local retval, user_params = reaper.GetUserInputs(
  "Track Setup", 2,
  "First Hardware Input (1-based):,1:1 Output Patch (Virtual Soundcheck)? (y/n):",
  "1,n"
)
if not retval then return end

local offset_str, vs_str = user_params:match("([^,]+),([^,]+)")
local hw_start = (tonumber(offset_str) or 1) - 1  -- convert to 0-based
local vs_mode  = (vs_str:lower():gsub("%s", "") == "y")

-- ─── Step 2: Parse Lines ─────────────────────────────────────────────────────
local lines = {}
for line in text_input:gmatch("[^\r\n]+") do
  local clean = line:gsub("^%d+%.?%s*", ""):gsub("^%s*(.-)%s*$", "%1")
  if clean ~= "" then table.insert(lines, clean) end
end

if #lines == 0 then
  reaper.ShowMessageBox("No valid track names found in clipboard!", "Error", 0)
  return
end

-- ─── Step 3: Detect Stereo Pairs ─────────────────────────────────────────────
-- pairs_found: list of { idx1, idx2, base_name }
-- is_paired[i] = true if line i is part of a detected pair
local pairs_found = {}
local is_paired   = {}

local i = 1
while i <= #lines do
  if lines[i + 1] then
    local matched = false
    for _, p in ipairs(STEREO_PATTERNS) do
      local b1 = lines[i]:match(p[1])
      local b2 = lines[i + 1]:match(p[2])
      if b1 and b2 and b1:lower() == b2:lower() then
        table.insert(pairs_found, {
          idx1      = i,
          idx2      = i + 1,
          base_name = b1:gsub("%s+$", ""),
          name1     = lines[i],
          name2     = lines[i + 1],
          as_stereo = true   -- default: checked
        })
        is_paired[i]     = #pairs_found
        is_paired[i + 1] = #pairs_found
        matched = true
        break
      end
    end
    if matched then i = i + 2 else i = i + 1 end
  else
    i = i + 1
  end
end

-- ─── Step 4: ReaImGui Stereo Confirmation (if pairs found) ──────────────────
local ctx

if #pairs_found > 0 then
  ctx = reaper.ImGui_CreateContext("JG Create Tracks")

  local FONT_SIZE = 15
  local open      = true
  local confirmed = false

  local function loop()
    if not open then
      reaper.ImGui_DestroyContext(ctx)
      if not confirmed then return end  -- user closed window = cancel
      -- proceed to track creation (falls through after defer chain ends)
      return
    end

    reaper.ImGui_SetNextWindowSize(ctx, 460, 300, reaper.ImGui_Cond_Once())
    local visible, win_open = reaper.ImGui_Begin(ctx, "Stereo Pairs detected – confirm", true)

    if visible then
      reaper.ImGui_Text(ctx, "The following stereo pairs were detected.")
      reaper.ImGui_Text(ctx, "Check which ones should be created as stereo:")
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Spacing(ctx)

      for pi, pair in ipairs(pairs_found) do
        local rv, checked = reaper.ImGui_Checkbox(
          ctx,
          string.format('"%s"  (%s / %s)', pair.base_name, pair.name1, pair.name2),
          pair.as_stereo
        )
        if rv then pairs_found[pi].as_stereo = checked end
      end

      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Spacing(ctx)

      if reaper.ImGui_Button(ctx, "Create Tracks", 120, 0) then
        confirmed = true
        open      = false
      end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Cancel", 80, 0) then
        open = false
      end

      reaper.ImGui_End(ctx)
    end

    if not win_open then open = false end

    if open then
      reaper.defer(loop)
    else
      reaper.ImGui_DestroyContext(ctx)
      if confirmed then
        create_all_tracks()
      end
    end
  end

  reaper.defer(loop)

else
  -- No pairs found, create directly
  create_all_tracks()
end

-- ─── Step 5: Create Tracks ───────────────────────────────────────────────────
function create_all_tracks()
  reaper.Undo_BeginBlock()

  if vs_mode then
    clear_master_hw_outputs()
  end

  -- Build a lookup: which pair index (if any) is each line part of, and is it stereo?
  local pair_for_line = {}
  for pi, pair in ipairs(pairs_found) do
    if pair.as_stereo then
      pair_for_line[pair.idx1] = { pair = pair, role = "first" }
      pair_for_line[pair.idx2] = { pair = pair, role = "second" }
    end
  end

  local hw_idx      = hw_start
  local mono_count  = 0
  local stereo_count = 0
  local j = 1

  while j <= #lines do
    local pf = pair_for_line[j]

    if pf and pf.role == "first" then
      -- ── Stereo Track ──
      local pair = pf.pair
      reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
      local tr = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
      reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", pair.base_name, true)
      reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 1)
      reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
      reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", 1024 + hw_idx)  -- stereo input

      if vs_mode then
        reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0)
        set_hw_output_via_chunk(tr, hw_idx, true)
      end

      hw_idx = hw_idx + 2
      stereo_count = stereo_count + 1
      j = j + 2  -- skip both lines

    elseif pf and pf.role == "second" then
      -- Should never happen (we skip with j+2), but safety guard
      j = j + 1

    elseif is_paired[j] then
      -- Part of a pair that was UNchecked (keep as mono)
      reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
      local tr = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
      reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", lines[j], true)
      reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 1)
      reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
      reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", hw_idx)

      if vs_mode then
        reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0)
        set_hw_output_via_chunk(tr, hw_idx, false)
      end

      hw_idx = hw_idx + 1
      mono_count = mono_count + 1
      j = j + 1

    else
      -- ── Mono Track ──
      reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
      local tr = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
      reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", lines[j], true)
      reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 1)
      reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
      reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", hw_idx)

      if vs_mode then
        reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0)
        set_hw_output_via_chunk(tr, hw_idx, false)
      end

      hw_idx = hw_idx + 1
      mono_count = mono_count + 1
      j = j + 1
    end
  end

  reaper.Undo_EndBlock("JG Create Tracks From Clipboard", -1)
  reaper.UpdateArrange()

  -- Summary
  local last_input = hw_idx  -- already 0-based+1 after last increment
  local summary = string.format(
    "Done!\n\nMono tracks:   %d\nStereo tracks: %d\n\nHardware inputs used: %d – %d",
    mono_count, stereo_count,
    hw_start + 1, last_input
  )
  reaper.ShowMessageBox(summary, "JG Create Tracks", 0)
end