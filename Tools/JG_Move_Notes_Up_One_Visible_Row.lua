-- @description Move notes up one visible row (drum-map / custom note order aware)
-- @author Julius Gass
-- @about
--   MIDI editor: moves every selected note UP by one VISIBLE ROW instead of by
--   one semitone.
--
--   * In a normally pitch-sorted map this is identical to one semitone up
--     (like the stock action 40177).
--   * In a drum map whose rows have been REORDERED (View > Mode: Named Notes,
--     custom note row order — articulations grouped by instrument), the note
--     jumps to the next visible row ABOVE in display order, even when that row
--     is several semitones away or out of pitch sequence.
--
--   How it works: REAPER stores the visual row order as a CUSTOM_NOTE_ORDER
--   line in the track state chunk (lowest visible row first). The script reads
--   that order (read-only) and steps one entry toward the top. It falls back to
--   a plain one-semitone move when the track has no custom order, or for a
--   selected note that sits on a row not present in the custom order.
--
--   Acts on all selected notes in the active MIDI editor take. Notes already on
--   the topmost visible row stay put (no wrap-around).
--
--   Pairs with: JG_Move_Notes_Down_One_Visible_Row.lua

local r = reaper
local DIR = 1 -- +1 = up (toward the top of the editor)

local function run()
  local me = r.MIDIEditor_GetActive()
  if not me then return end
  local take = r.MIDIEditor_GetTake(me)
  if not take or not r.ValidatePtr2(0, take, "MediaItem_Take*") then return end
  local track = r.GetMediaItemTake_Track(take)

  -- Read the custom display order (lowest visible row first) from the chunk.
  local order, idxOf
  local ok, chunk = r.GetTrackStateChunk(track, "", false)
  if ok then
    local line = ("\n" .. chunk):match("\nCUSTOM_NOTE_ORDER ([^\r\n]+)")
    if line then
      order, idxOf = {}, {}
      for n in line:gmatch("%d+") do
        local p = tonumber(n)
        order[#order + 1] = p
        idxOf[p] = #order
      end
      if #order == 0 then order, idxOf = nil, nil end
    end
  end

  -- Target pitch for one source pitch.
  local function target(pitch)
    if idxOf then
      local k = idxOf[pitch]
      if k then
        local nk = k + DIR
        if nk >= 1 and nk <= #order then return order[nk] end
        return pitch -- already on the edge row: do not move
      end
    end
    local p = pitch + DIR -- no custom order, or note on an unlisted row
    if p < 0 then p = 0 elseif p > 127 then p = 127 end
    return p
  end

  -- Collect first; we only change pitch, so note indices stay valid.
  local moves, i = {}, -1
  while true do
    i = r.MIDI_EnumSelNotes(take, i)
    if i == -1 then break end
    local _, _, _, _, _, _, pitch = r.MIDI_GetNote(take, i)
    local np = target(pitch)
    if np ~= pitch then moves[#moves + 1] = { i, np } end
  end
  if #moves == 0 then return end

  r.Undo_BeginBlock2(0)
  for _, m in ipairs(moves) do
    r.MIDI_SetNote(take, m[1], nil, nil, nil, nil, nil, m[2], nil, true) -- noSort
  end
  r.MIDI_Sort(take)
  r.Undo_EndBlock2(0, "Move notes up one visible row", -1)
end

run()
