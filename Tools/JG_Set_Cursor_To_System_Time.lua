-- @description Set cursor to system time
-- @author JG
-- @version 1.0.0
-- @about
--   Sets the timeline to timecode (HH:MM:SS:FF), sets the project start to 00:00:00, 
--   and moves the edit cursor to the current system time.

function Main()
    -- Get current system time
    local current_time = os.date("*t")
    local hours = current_time.hour
    local minutes = current_time.min
    local seconds = current_time.sec
    
    -- Convert to seconds since start of day (00:00:00)
    local time_in_seconds = hours * 3600 + minutes * 60 + seconds
    
    -- Switch timeline to timecode mode (hh:mm:ss:ff)
    reaper.Main_OnCommand(40370, 0) -- Time unit for ruler: Hours:Minutes:Seconds:Frames
    
    -- Set project start to 00:00:00
    reaper.GetSetProjectInfo(0, "PROJ_START", 0, true)
    
    -- Set edit cursor to current time of day
    reaper.SetEditCurPos(time_in_seconds, true, true)
    
    -- Status message
    local time_string = string.format("%02d:%02d:%02d", hours, minutes, seconds)
    reaper.ShowConsoleMsg("Timeline switched to timecode\n")
    reaper.ShowConsoleMsg("Cursor set to: " .. time_string .. "\n")
    
    -- Scroll timeline to cursor
    reaper.Main_OnCommand(40913, 0)
    
    -- Update view
    reaper.UpdateArrange()
end

-- Undo block
reaper.Undo_BeginBlock()
Main()
reaper.Undo_EndBlock("Set timeline to timecode and cursor to system time", -1)