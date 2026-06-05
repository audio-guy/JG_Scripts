-- @description Reference Level Follow (ride a track's level to follow a reference's dynamics)
-- @author JG
-- @version 1.2.2
-- @about
--   Makes one or more "destination" tracks (e.g. a choir/piano backing with a
--   roughly constant level) follow the macro dynamics of a "source" reference
--   (e.g. a finished stereo mix). It measures the reference's short-term
--   loudness (BS.1770-4 K-weighting) over time and writes a smoothed Pre-FX
--   volume automation envelope onto the destinations, so they get louder where
--   the reference is loud and quieter where it is quiet.
--
--   The ride is centred on the reference's median loudness (= 0 dB), so the
--   destinations' static fader level is preserved on average; only deviations
--   are followed. The ride is applied on a separate stage (Pre-FX volume or a
--   gain JSFX at the end of the chain), leaving your main fader untouched.
--
--   GUI:
--     Sources       - reference track(s) to follow (summed if several)
--     Destinations  - track(s) to write the ride envelope onto
--     Source tap    - Item (raw) / Track post-FX / Post-fader (incl. source
--                     volume automation) to measure the reference from
--     Apply on dest - Pre-FX volume envelope, or a self-contained gain JSFX at
--                     the end of the chain (leaves the volume envelope free)
--     Follow amount - how steeply the ride tracks the reference (slope/depth)
--     Inertia       - smoothing time; higher = slower, more "organic"
--     Ride range    - hard floor/ceiling (lower/upper dB limits) for the ride
--   If a time selection exists, only that range is analysed/written.
--   During a reference rest (silence) the ride follows down to the lower limit.
--
--   Requires the js_ReaScriptAPI-independent ReaImGui extension (ReaPack).

local r = reaper

if not r.ImGui_CreateContext then
  r.MB("This script requires ReaImGui.\n\nInstall it via ReaPack:\nExtensions > ReaPack > Browse packages > search \"ReaImGui\".",
       "Missing dependency", 0)
  return
end

-- ════════════════════════════════════════════════════════════════════════
--  Config / state
-- ════════════════════════════════════════════════════════════════════════
local EXT          = "JG_ReferenceLevelFollow"
local ANALYSIS_SR  = 16000
local HOP_SEC      = 0.1
local SILENCE_LUFS = -70          -- below this a block counts as a rest
local POINT_DELTA  = 0.05         -- dB change needed to emit a new envelope point

local cfg   = { sources = {}, dests = {} }            -- track GUIDs (per project)
local prefs = { depth = 50, inertia = 2.0, lowerLimit = -12, upperLimit = 6,
                srcMode = "item", dstMode = "prefx" } -- global
local cache = { key = nil, times = nil, loud = nil }  -- analysis cache
local state = { status = "Pick sources + destinations, then Analyze & Write." }
local prefsDirty = false

-- ════════════════════════════════════════════════════════════════════════
--  Persistence
-- ════════════════════════════════════════════════════════════════════════
local function split(s)
  local t = {}
  for x in (s or ""):gmatch("[^,]+") do t[#t+1] = x end
  return t
end

local function saveCfg()
  r.SetProjExtState(0, EXT, "sources", table.concat(cfg.sources, ","))
  r.SetProjExtState(0, EXT, "dests",   table.concat(cfg.dests, ","))
end

local function loadCfg()
  local _, s = r.GetProjExtState(0, EXT, "sources")
  local _, d = r.GetProjExtState(0, EXT, "dests")
  cfg.sources = split(s)
  cfg.dests   = split(d)
end

local function savePrefs()
  r.SetExtState(EXT, "depth",    tostring(prefs.depth),    true)
  r.SetExtState(EXT, "inertia",  tostring(prefs.inertia),  true)
  r.SetExtState(EXT, "lower", tostring(prefs.lowerLimit), true)
  r.SetExtState(EXT, "upper", tostring(prefs.upperLimit), true)
  r.SetExtState(EXT, "srcmode", prefs.srcMode, true)
  r.SetExtState(EXT, "dstmode", prefs.dstMode, true)
end

local function loadPrefs()
  prefs.depth   = tonumber(r.GetExtState(EXT, "depth"))   or prefs.depth
  prefs.inertia = tonumber(r.GetExtState(EXT, "inertia")) or prefs.inertia
  -- migrate old maxboost/maxcut (positive) to signed lower/upper limits
  local oldB = tonumber(r.GetExtState(EXT, "maxboost"))
  local oldC = tonumber(r.GetExtState(EXT, "maxcut"))
  prefs.lowerLimit = tonumber(r.GetExtState(EXT, "lower")) or (oldC and -oldC) or prefs.lowerLimit
  prefs.upperLimit = tonumber(r.GetExtState(EXT, "upper")) or oldB or prefs.upperLimit
  local sm = r.GetExtState(EXT, "srcmode"); if sm ~= "" then prefs.srcMode = sm end
  local dm = r.GetExtState(EXT, "dstmode"); if dm ~= "" then prefs.dstMode = dm end
end

-- ════════════════════════════════════════════════════════════════════════
--  Track helpers
-- ════════════════════════════════════════════════════════════════════════
local function captureSelected()
  local g = {}
  for i = 0, r.CountSelectedTracks(0) - 1 do
    g[#g + 1] = r.GetTrackGUID(r.GetSelectedTrack(0, i))
  end
  return g
end

local function resolveTracks(guidList)
  local want = {}
  for _, g in ipairs(guidList) do want[g] = true end
  local out = {}
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    if want[r.GetTrackGUID(tr)] then out[#out + 1] = tr end
  end
  return out
end

local function namesFor(guidList)
  local trs = resolveTracks(guidList)
  if #trs == 0 then return "(none)" end
  local names = {}
  for _, tr in ipairs(trs) do
    local _, nm = r.GetTrackName(tr)
    names[#names + 1] = nm
  end
  return table.concat(names, ", ")
end

local function saveTrackSelection()
  local s = {}
  for i = 0, r.CountSelectedTracks(0) - 1 do s[#s + 1] = r.GetSelectedTrack(0, i) end
  return s
end

local function restoreTrackSelection(s)
  for i = 0, r.CountTracks(0) - 1 do r.SetTrackSelected(r.GetTrack(0, i), false) end
  for _, tr in ipairs(s) do r.SetTrackSelected(tr, true) end
end

-- Pre-FX volume envelope, created if absent (action 41865 = toggle pre-FX vol env).
local function getPreFXVolEnv(track)
  local env = r.GetTrackEnvelopeByChunkName(track, "<VOLENV")
  if env then return env end
  r.SetOnlyTrackSelected(track)
  r.Main_OnCommand(41865, 0)
  return r.GetTrackEnvelopeByChunkName(track, "<VOLENV")
end

-- Self-contained gain JSFX (written to the resource path on first use), so the
-- ride can sit at the end of the FX chain without a ReaPack dependency.
local RIDE_JSFX_NAME = "JG_RideGain"
local RIDE_JSFX_LO, RIDE_JSFX_HI = -24, 12   -- must match slider1 range below

local function ensureRideJSFX()
  local path = r.GetResourcePath() .. "/Effects/" .. RIDE_JSFX_NAME
  local fh = io.open(path, "r")
  if fh then fh:close(); return RIDE_JSFX_NAME end
  fh = io.open(path, "w")
  if not fh then return nil end
  fh:write(
    "desc:JG Ride Gain\n" ..
    "slider1:0<-24,12,0.001>Ride gain (dB)\n" ..
    "@init\ng = 10^(slider1/20);\n" ..
    "@slider\ng = 10^(slider1/20);\n" ..
    "@sample\nspl0 *= g; spl1 *= g;\n")
  fh:close()
  return RIDE_JSFX_NAME
end

-- Locate an existing JG Ride Gain instance on the track (by name, any position).
local function findRideFX(track)
  for i = 0, r.TrackFX_GetCount(track) - 1 do
    local _, nm = r.TrackFX_GetFXName(track, i, "")
    if nm:find("JG Ride Gain", 1, true) or nm:find(RIDE_JSFX_NAME, 1, true) then
      return i
    end
  end
  return -1
end

-- Reuse the existing gain JSFX (wherever it sits in the chain) or add one at the
-- end; return its param-0 envelope.
local function getGainParamEnv(track)
  local fx = findRideFX(track)
  if fx < 0 then
    local name = ensureRideJSFX()
    if not name then return nil end
    fx = r.TrackFX_AddByName(track, name, false, 1)
  end
  if fx < 0 then return nil end
  return r.GetFXEnvelope(track, fx, 0, true)
end

-- Analysis time range: time selection if set, else union of source content.
local function getRange(srcTracks)
  local s, e = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if e > s then return s, e end
  local lo, hi = math.huge, -math.huge
  for _, tr in ipairs(srcTracks) do
    local acc = r.CreateTrackAudioAccessor(tr)
    local a = r.GetAudioAccessorStartTime(acc)
    local b = r.GetAudioAccessorEndTime(acc)
    r.DestroyAudioAccessor(acc)
    if a < lo then lo = a end
    if b > hi then hi = b end
  end
  if hi <= lo then lo, hi = 0, r.GetProjectLength(0) end
  if lo < 0 then lo = 0 end
  return lo, hi
end

-- ════════════════════════════════════════════════════════════════════════
--  K-Weighting (BS.1770-4, bilinear transform) — proven engine
-- ════════════════════════════════════════════════════════════════════════
local function kweight_coeffs(sr)
  local pi = math.pi
  -- Stage 1: High-Shelf +4 dB @ 1681.97 Hz, Q 0.7072
  local A   = 10 ^ (4 / 40)
  local sqA = math.sqrt(A)
  local f0  = 1681.974450955533
  local Q   = 0.7071752369554196
  local w0  = 2 * pi * f0 / sr
  local c0, s0 = math.cos(w0), math.sin(w0)
  local al  = s0 / (2 * Q)
  local b0  =  A * ((A+1) + (A-1)*c0 + 2*sqA*al)
  local b1  = -2 * A * ((A-1) + (A+1)*c0)
  local b2  =  A * ((A+1) + (A-1)*c0 - 2*sqA*al)
  local a0  = (A+1) - (A-1)*c0 + 2*sqA*al
  local a1  =  2 * ((A-1) - (A+1)*c0)
  local a2  = (A+1) - (A-1)*c0 - 2*sqA*al
  local hs  = {b0/a0, b1/a0, b2/a0, a1/a0, a2/a0}
  -- Stage 2: Butterworth HP 2nd order @ 38.14 Hz
  local f1  = 38.13547087602444
  local w1  = 2 * pi * f1 / sr
  local c1, s1 = math.cos(w1), math.sin(w1)
  local al1 = s1 / math.sqrt(2)
  local d0  = (1 + c1) / 2;  local d1 = -(1 + c1);  local d2 = (1 + c1) / 2
  local e0  = 1 + al1;       local e1 = -2 * c1;     local e2 = 1 - al1
  local hp  = {d0/e0, d1/e0, d2/e0, e1/e0, e2/e0}
  return hs, hp
end

-- Returns time[] (project sec) and loud[] (LUFS) per 100 ms block of the source sum.
local function analyze(srcTracks, t0, t1, srcMode)
  local sr  = ANALYSIS_SR
  local hs, hp = kweight_coeffs(sr)
  local hs0,hs1,hs2,ha1,ha2 = hs[1],hs[2],hs[3],hs[4],hs[5]
  local hp0,hp1,hp2,pa1,pa2 = hp[1],hp[2],hp[3],hp[4],hp[5]
  local ax1,ax2,ay1,ay2 = 0,0,0,0
  local ap1,ap2,aq1,aq2 = 0,0,0,0
  local bx1,bx2,by1,by2 = 0,0,0,0
  local bp1,bp2,bq1,bq2 = 0,0,0,0

  local hop   = math.floor(HOP_SEC * sr)
  local LOG10 = 0.4342944819032518
  local CH    = 2
  local CHUNK = 65536

  -- Item (raw): bypass each source track's FX chain while reading.
  local fxSaved = {}
  if srcMode == "item" then
    for k, tr in ipairs(srcTracks) do
      fxSaved[k] = r.GetMediaTrackInfo_Value(tr, "I_FXEN")
      r.SetMediaTrackInfo_Value(tr, "I_FXEN", 0)
    end
  end

  local accs, bufs = {}, {}
  for k, tr in ipairs(srcTracks) do
    accs[k] = r.CreateTrackAudioAccessor(tr)
    bufs[k] = r.new_array(CHUNK * CH)
  end

  local times, loud = {}, {}
  local slotSum, slotCnt = 0.0, 0
  local slotStart = t0
  local nsrc = #srcTracks

  local t = t0
  while t < t1 - 1e-9 do
    local want = math.min(CHUNK, math.floor((t1 - t) * sr + 0.5))
    if want <= 0 then break end
    for k = 1, nsrc do
      r.GetAudioAccessorSamples(accs[k], sr, CH, t, want, bufs[k])
    end
    for i = 0, want - 1 do
      local x1, x2 = 0.0, 0.0
      for k = 1, nsrc do
        local b = bufs[k]
        x1 = x1 + b[i*2+1]
        x2 = x2 + b[i*2+2]
      end
      local yA = hs0*x1 + hs1*ax1 + hs2*ax2 - ha1*ay1 - ha2*ay2
      ax2=ax1; ax1=x1; ay2=ay1; ay1=yA
      local yB = hp0*yA + hp1*ap1 + hp2*ap2 - pa1*aq1 - pa2*aq2
      ap2=ap1; ap1=yA; aq2=aq1; aq1=yB
      local yC = hs0*x2 + hs1*bx1 + hs2*bx2 - ha1*by1 - ha2*by2
      bx2=bx1; bx1=x2; by2=by1; by1=yC
      local yD = hp0*yC + hp1*bp1 + hp2*bp2 - pa1*bq1 - pa2*bq2
      bp2=bp1; bp1=yC; bq2=bq1; bq1=yD

      slotSum = slotSum + (yB*yB + yD*yD) * 0.5
      slotCnt = slotCnt + 1
      if slotCnt >= hop then
        local ms = slotSum / slotCnt
        loud[#loud + 1]  = (ms > 1e-12) and (-0.691 + 10*math.log(ms)*LOG10) or -150.0
        times[#times + 1] = slotStart + HOP_SEC * 0.5
        slotSum, slotCnt = 0.0, 0
        slotStart = slotStart + HOP_SEC
      end
    end
    t = t + want / sr
  end

  if slotCnt > 0 then
    local ms = slotSum / slotCnt
    loud[#loud + 1]  = (ms > 1e-12) and (-0.691 + 10*math.log(ms)*LOG10) or -150.0
    times[#times + 1] = slotStart + HOP_SEC * 0.5
  end

  for k = 1, nsrc do r.DestroyAudioAccessor(accs[k]) end

  if srcMode == "item" then
    for k, tr in ipairs(srcTracks) do
      r.SetMediaTrackInfo_Value(tr, "I_FXEN", fxSaved[k] or 1)
    end
  end

  -- Post-fader: fold in the source's time-varying volume automation (the static
  -- fader cancels via the median). Exact for a single source track.
  if srcMode == "postfader" and srcTracks[1] then
    local env = r.GetTrackEnvelopeByName(srcTracks[1], "Volume")
    if env then
      local scaling = r.GetEnvelopeScalingMode(env)
      for i = 1, #loud do
        local _, v = r.Envelope_Evaluate(env, times[i], 44100, 1)
        local lin = r.ScaleFromEnvelopeMode(scaling, v)
        if lin and lin > 1e-9 then loud[i] = loud[i] + 20 * math.log(lin) * LOG10 end
      end
    end
  end

  return times, loud
end

local function ensureAnalysis(srcTracks, t0, t1, srcMode)
  local key = srcMode .. "|"
  for _, tr in ipairs(srcTracks) do key = key .. r.GetTrackGUID(tr) end
  key = key .. string.format("|%.3f|%.3f|%d", t0, t1, ANALYSIS_SR)
  if cache.key == key and cache.times then return cache.times, cache.loud end
  local times, loud = analyze(srcTracks, t0, t1, srcMode)
  cache.key, cache.times, cache.loud = key, times, loud
  return times, loud
end

-- ════════════════════════════════════════════════════════════════════════
--  Gain derivation (depth, anchor, limits, zero-phase smoothing)
-- ════════════════════════════════════════════════════════════════════════
local function median(vals)
  local c = {}
  for _, v in ipairs(vals) do c[#c + 1] = v end
  table.sort(c)
  local n = #c
  if n == 0 then return nil end
  local mid = math.floor(n / 2)
  if n % 2 == 1 then return c[mid + 1] else return 0.5 * (c[mid] + c[mid + 1]) end
end

local function deriveGain(times, loud)
  local depth = prefs.depth / 100
  local lo, hi = prefs.lowerLimit, prefs.upperLimit
  if lo > hi then lo, hi = hi, lo end
  local n = #loud

  local nz = {}
  for _, L in ipairs(loud) do if L > SILENCE_LUFS then nz[#nz + 1] = L end end
  local anchor = median(nz) or -23

  local g = {}
  for i = 1, n do
    local L = loud[i]
    local gv
    if L <= SILENCE_LUFS then gv = lo else gv = depth * (L - anchor) end
    if gv > hi then gv = hi elseif gv < lo then gv = lo end
    g[i] = gv
  end

  -- zero-phase one-pole smoothing (forward + backward), tau = inertia
  local alpha = 1 - math.exp(-HOP_SEC / math.max(prefs.inertia, 1e-3))
  local s = g[1] or 0
  local f = {}
  for i = 1, n do s = s + alpha * (g[i] - s); f[i] = s end
  s = f[n] or 0
  for i = n, 1, -1 do s = s + alpha * (f[i] - s); g[i] = s end
  for i = 1, n do
    if g[i] > hi then g[i] = hi elseif g[i] < lo then g[i] = lo end
  end
  return g, anchor
end

-- ════════════════════════════════════════════════════════════════════════
--  Envelope writing
-- ════════════════════════════════════════════════════════════════════════
local function writeEnvelopes(destTracks, times, g, t0, t1)
  local sel = saveTrackSelection()
  r.PreventUIRefresh(1)
  r.Undo_BeginBlock()
  local written = 0
  local n = #g
  for _, tr in ipairs(destTracks) do
    -- pick the target envelope and the dB -> envelope-value mapping for this mode
    local env, toValue
    if prefs.dstMode == "jsfx" then
      env = getGainParamEnv(tr)
      -- A JSFX slider's parameter value space IS the slider's own range (dB
      -- here), not normalised 0..1 — write the dB value directly.
      toValue = function(db)
        if db < RIDE_JSFX_LO then return RIDE_JSFX_LO end
        if db > RIDE_JSFX_HI then return RIDE_JSFX_HI end
        return db
      end
    else
      env = getPreFXVolEnv(tr)
      if env then
        local scaling = r.GetEnvelopeScalingMode(env)
        toValue = function(db) return r.ScaleToEnvelopeMode(scaling, 10 ^ (db / 20)) end
      end
    end

    if env and toValue and n > 0 then
      r.DeleteEnvelopePointRange(env, t0 - 0.0011, t1 + 0.0011)
      local function put(i) r.InsertEnvelopePoint(env, times[i], toValue(g[i]), 0, 0, false, true) end
      put(1)
      local lastDb = g[1]
      for i = 2, n - 1 do
        if math.abs(g[i] - lastDb) >= POINT_DELTA then put(i); lastDb = g[i] end
      end
      if n > 1 then put(n) end
      r.Envelope_SortPoints(env)
      written = written + 1
    end
  end
  r.Undo_EndBlock("Reference Level Follow: write envelopes", -1)
  r.PreventUIRefresh(-1)
  restoreTrackSelection(sel)
  r.UpdateArrange()
  return written
end

-- ════════════════════════════════════════════════════════════════════════
--  Actions
-- ════════════════════════════════════════════════════════════════════════
local function runAnalyzeWrite()
  local srcs  = resolveTracks(cfg.sources)
  local dests = resolveTracks(cfg.dests)
  if #srcs  == 0 then state.status = "Pick source track(s) first.";      return end
  if #dests == 0 then state.status = "Pick destination track(s) first."; return end
  local t0, t1 = getRange(srcs)
  if t1 <= t0 then state.status = "Empty analysis range."; return end

  local times, loud = ensureAnalysis(srcs, t0, t1, prefs.srcMode)
  if #loud == 0 then state.status = "No audio found in range."; return end
  local g, anchor = deriveGain(times, loud)
  local written = writeEnvelopes(dests, times, g, t0, t1)
  state.status = string.format("Done: %d blocks, anchor %.1f LUFS, %d/%d destination(s) written.",
                               #loud, anchor, written, #dests)
end

local function runClear()
  local dests = resolveTracks(cfg.dests)
  if #dests == 0 then state.status = "Pick destination track(s) first."; return end
  local srcs = resolveTracks(cfg.sources)
  local t0, t1 = getRange(#srcs > 0 and srcs or dests)
  r.Undo_BeginBlock()
  for _, tr in ipairs(dests) do
    local env
    if prefs.dstMode == "jsfx" then
      local fx = findRideFX(tr)
      if fx >= 0 then env = r.GetFXEnvelope(tr, fx, 0, false) end
    else
      env = r.GetTrackEnvelopeByChunkName(tr, "<VOLENV")
    end
    if env then
      r.DeleteEnvelopePointRange(env, t0 - 0.0011, t1 + 0.0011)
      r.Envelope_SortPoints(env)
    end
  end
  r.Undo_EndBlock("Reference Level Follow: clear envelopes", -1)
  r.UpdateArrange()
  state.status = "Cleared ride envelope in range on destination(s)."
end

-- ════════════════════════════════════════════════════════════════════════
--  GUI
-- ════════════════════════════════════════════════════════════════════════
local ctx  = r.ImGui_CreateContext("JG Reference Level Follow")
local font = r.ImGui_CreateFont("sans-serif", 14)
r.ImGui_Attach(ctx, font)

local function drawGUI()
  r.ImGui_Text(ctx, "Sources (reference to follow):")
  if r.ImGui_Button(ctx, "Capture from selected##src", 210, 24) then
    cfg.sources = captureSelected(); cache.key = nil; saveCfg()
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_Text(ctx, namesFor(cfg.sources))

  r.ImGui_Text(ctx, "Destinations (tracks to ride):")
  if r.ImGui_Button(ctx, "Capture from selected##dst", 210, 24) then
    cfg.dests = captureSelected(); saveCfg()
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_Text(ctx, namesFor(cfg.dests))

  r.ImGui_Separator(ctx)

  -- Source tap point
  local function srcRadio(label, mode)
    if r.ImGui_RadioButton(ctx, label, prefs.srcMode == mode) then
      if prefs.srcMode ~= mode then prefs.srcMode = mode; cache.key = nil; prefsDirty = true end
    end
  end
  r.ImGui_Text(ctx, "Source tap:"); r.ImGui_SameLine(ctx)
  srcRadio("Item (raw)", "item");      r.ImGui_SameLine(ctx)
  srcRadio("Track post-FX", "prefader"); r.ImGui_SameLine(ctx)
  srcRadio("Post-fader", "postfader")

  -- Destination apply point
  local function dstRadio(label, mode)
    if r.ImGui_RadioButton(ctx, label, prefs.dstMode == mode) then
      if prefs.dstMode ~= mode then prefs.dstMode = mode; prefsDirty = true end
    end
  end
  r.ImGui_Text(ctx, "Apply on dest:"); r.ImGui_SameLine(ctx)
  dstRadio("Pre-FX volume", "prefx");  r.ImGui_SameLine(ctx)
  dstRadio("Gain JSFX (end)", "jsfx")

  r.ImGui_Separator(ctx)

  local ch
  ch, prefs.depth   = r.ImGui_SliderDouble(ctx, "Follow amount", prefs.depth,   0, 100, "%.0f %%")
  if ch then prefsDirty = true end
  ch, prefs.inertia = r.ImGui_SliderDouble(ctx, "Inertia",       prefs.inertia, 0.1, 6.0, "%.1f s")
  if ch then prefsDirty = true end
  ch, prefs.lowerLimit, prefs.upperLimit =
    r.ImGui_DragFloatRange2(ctx, "Ride range (dB)", prefs.lowerLimit, prefs.upperLimit,
                            0.1, -24, 12, "%.1f", "%.1f")
  if ch then prefsDirty = true end
  r.ImGui_TextWrapped(ctx,
    "Follow amount = slope (at 100%, ref +6 dB over its median -> +6 dB ride). " ..
    "Ride range = lower/upper hard limits; reference rests fall to the lower limit.")

  r.ImGui_Separator(ctx)

  if r.ImGui_Button(ctx, "Analyze & Write", 160, 28) then runAnalyzeWrite() end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Clear", 90, 28) then runClear() end

  r.ImGui_Spacing(ctx)
  r.ImGui_Text(ctx, state.status)
  r.ImGui_Spacing(ctx)
  r.ImGui_TextWrapped(ctx,
    "Ride is centred on the reference's median loudness (0 dB) and written to the " ..
    "chosen destination stage. First analysis reads the audio (window may freeze " ..
    "briefly); changing sliders/limits and re-writing is instant. Set a time " ..
    "selection to limit the range.")
end

local function loop()
  r.ImGui_PushFont(ctx, font, 14)
  r.ImGui_SetNextWindowSize(ctx, 540, 470, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, "JG Reference Level Follow", true)
  if visible then
    drawGUI()
    r.ImGui_End(ctx)
  end
  r.ImGui_PopFont(ctx)

  if prefsDirty then savePrefs(); prefsDirty = false end
  if open then r.defer(loop) end
end

-- Entry
loadPrefs()
loadCfg()
r.atexit(savePrefs)
loop()
