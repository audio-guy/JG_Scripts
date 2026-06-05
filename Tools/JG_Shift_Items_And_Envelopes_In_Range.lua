-- @description Shift items and envelopes in time selection by an offset
-- @author JG
-- @version 1.0.0
-- @about
--   Moves everything inside the time selection by a chosen offset (seconds):
--     * media items (their take envelopes follow automatically)
--     * track-envelope points — point SHAPE and TENSION are preserved, so
--       square/hold points survive (incl. FX-parameter envelopes)
--     * automation items
--   Nothing outside the time selection is touched. Run again with the negated
--   offset to round-trip / undo the move exactly.
--
--   Prompt:
--     Offset (seconds) — positive = later, negative = earlier
--     Mode  both | points | ai — restrict envelope handling to raw points or
--           automation items only (default both). Items always move.

local r = reaper

local function in_range(t, t0, t1) return t >= t0 - 1e-9 and t <= t1 + 1e-9 end

local function shift_range(t0, t1, offset, do_points, do_autoitems)
  local rep = { items = 0, take_envs = 0, points = 0, autoitems = 0, envelopes = 0 }

  -- 1) media items (collect first; moving can reorder a track's item list)
  local to_move = {}
  for ti = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, ti)
    for ii = 0, r.CountTrackMediaItems(tr) - 1 do
      local it  = r.GetTrackMediaItem(tr, ii)
      local pos = r.GetMediaItemInfo_Value(it, "D_POSITION")
      if in_range(pos, t0, t1) then to_move[#to_move + 1] = { it = it, pos = pos } end
    end
  end
  for _, e in ipairs(to_move) do
    r.SetMediaItemInfo_Value(e.it, "D_POSITION", e.pos + offset)
    rep.items = rep.items + 1
    local tk = r.GetActiveTake(e.it)
    if tk then rep.take_envs = rep.take_envs + r.CountTakeEnvelopes(tk) end
  end

  -- 2) track envelopes: raw points and/or automation items
  for ti = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, ti)
    for ei = 0, r.CountTrackEnvelopes(tr) - 1 do
      local env = r.GetTrackEnvelope(tr, ei)
      local touched = false
      if do_points then
        for pi = 0, r.CountEnvelopePoints(env) - 1 do
          local ok, time, value, shape, tension, sel = r.GetEnvelopePoint(env, pi)
          if ok and in_range(time, t0, t1) then
            -- preserve value, SHAPE and TENSION (square/hold points must survive)
            r.SetEnvelopePoint(env, pi, time + offset, value, shape, tension, sel, true)
            rep.points = rep.points + 1
            touched = true
          end
        end
      end
      if do_autoitems then
        for ai = 0, r.CountAutomationItems(env) - 1 do
          local pos = r.GetSetAutomationItemInfo(env, ai, "D_POSITION", 0, false)
          if in_range(pos, t0, t1) then
            r.GetSetAutomationItemInfo(env, ai, "D_POSITION", pos + offset, true)
            rep.autoitems = rep.autoitems + 1
            touched = true
          end
        end
      end
      if touched then r.Envelope_SortPoints(env); rep.envelopes = rep.envelopes + 1 end
    end
  end

  return rep
end

local t0, t1 = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
if t1 <= t0 then
  r.MB("Make a time selection over the range to shift first.", "Shift Items & Envelopes", 0)
  return
end

local ok, csv = r.GetUserInputs("Shift Items & Envelopes in Range", 2,
  "Offset (seconds):,Mode (both/points/ai):", "5,both")
if not ok then return end

local offset_s, mode = csv:match("([^,]*),([^,]*)")
local offset = tonumber(offset_s)
if not offset then
  r.MB("Invalid offset — enter a number of seconds (e.g. 5 or -5).", "Shift Items & Envelopes", 0)
  return
end
mode = (mode or "both"):gsub("%s", ""):lower()
local do_points    = (mode == "both" or mode == "points")
local do_autoitems = (mode == "both" or mode == "ai")

r.Undo_BeginBlock()
r.PreventUIRefresh(1)
local rep = shift_range(t0, t1, offset, do_points, do_autoitems)
r.PreventUIRefresh(-1)
r.UpdateArrange()
r.Undo_EndBlock("Shift items and envelopes in range", -1)

r.ShowConsoleMsg(string.format(
  "Shift items & envelopes — %.3f to %.3f s by %+.3f s (mode: %s)\n" ..
  "  items moved: %d   (take envelopes carried: %d)\n" ..
  "  track-env points moved: %d   (shape + tension preserved)\n" ..
  "  automation items moved: %d\n" ..
  "  envelopes touched: %d\n",
  t0, t1, offset, mode, rep.items, rep.take_envs, rep.points, rep.autoitems, rep.envelopes))
