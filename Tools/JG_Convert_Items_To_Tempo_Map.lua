-- @description Convert items to tempo map
-- @author JG
-- @version 1.0.0
-- @about
--   Creates a tempo map based on the distance between selected items.
--   Includes user inputs for time signature and click basis (e.g., quarter notes, dotted eighths).

local count = reaper.CountSelectedMediaItems(0)
if count < 2 then return end

local ret, inputs = reaper.GetUserInputs("Tempo Map Settings", 3, "Time Sig Num (0=ignore):,Time Sig Den (0=ignore):,Click Basis (2, 4, 8, 4.):", "4,4,4")
if not ret then return end

local num_str, den_str, click_str = inputs:match("([^,]+),([^,]+),([^,]+)")
local num = tonumber(num_str) or 0
local den = tonumber(den_str) or 0

local is_dotted = click_str:match("%.") ~= nil
local click_clean = click_str:gsub("%.", "")
local click_val = tonumber(click_clean) or 4
local qn_multiplier = 4.0 / click_val
if is_dotted then qn_multiplier = qn_multiplier * 1.5 end

reaper.Undo_BeginBlock()

-- Force track timebase to "Time" to prevent items from shifting
local track = reaper.GetMediaItemTrack(reaper.GetSelectedMediaItem(0, 0))
reaper.SetMediaTrackInfo_Value(track, "C_BEATATTACHMODE", 0)

local prev_bpm = -1

for i = 0, count - 2 do
    local item1 = reaper.GetSelectedMediaItem(0, i)
    local item2 = reaper.GetSelectedMediaItem(0, i + 1)
    local pos1 = reaper.GetMediaItemInfo_Value(item1, "D_POSITION")
    local pos2 = reaper.GetMediaItemInfo_Value(item2, "D_POSITION")
    
    local diff = pos2 - pos1
    if diff > 0 then
        local bpm = (60.0 * qn_multiplier) / diff
        
        -- Nur Marker setzen, wenn sich das Tempo ändert
        if math.abs(bpm - prev_bpm) > 0.001 then
            -- Taktart nur beim allerersten Marker setzen, danach 0 (keine Änderung)
            local m_num = (i == 0) and num or 0
            local m_den = (i == 0) and den or 0
            
            reaper.SetTempoTimeSigMarker(0, -1, pos1, -1, -1, bpm, m_num, m_den, false)
            prev_bpm = bpm
        end
    end
end

reaper.UpdateTimeline()
reaper.Undo_EndBlock("Create tempo map from items", -1)