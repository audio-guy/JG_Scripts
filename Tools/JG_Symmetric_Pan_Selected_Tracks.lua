-- @description Symmetric pan selected tracks (user input width)
-- @author JG
-- @version 1.0.0
-- @about
--   Pans selected tracks symmetrically left and right based on user input width (0-100).

function main()
    -- Get number of selected tracks
    local count_sel_tracks = reaper.CountSelectedTracks(0)
    
    -- Error check: We need at least 2 tracks for a spread
    if count_sel_tracks < 2 then
        reaper.ShowMessageBox("Please select at least 2 tracks to spread them.", "Info", 0)
        return
    end

    -- Popup for user input
    local retval, user_input = reaper.GetUserInputs("Symmetric Panning", 1, "Width (0-100):", "100")

    -- Cancel if user aborted
    if not retval then return end

    -- Convert input to number
    local width = tonumber(user_input)

    -- Abort if no valid number was entered
    if not width then return end

    -- Clamp values between 0 and 100
    if width > 100 then width = 100 end
    if width < 0 then width = 0 end

    -- Reaper calculates pan from -1.0 (L) to +1.0 (R)
    local max_pan_factor = width / 100

    reaper.Undo_BeginBlock()

    -- Loop through all selected tracks
    for i = 0, count_sel_tracks - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        
        -- Calculate position progress (0.0 to 1.0)
        local progress = i / (count_sel_tracks - 1)
        
        -- Map progress to pan values
        local new_pan = -max_pan_factor + (progress * (max_pan_factor * 2))

        -- Set pan
        reaper.SetMediaTrackInfo_Value(track, "D_PAN", new_pan)
    end

    reaper.Undo_EndBlock("Symmetric Panning (" .. width .. "%)", -1)
    reaper.UpdateArrange()
end

reaper.PreventUIRefresh(1)
main()
reaper.PreventUIRefresh(-1)