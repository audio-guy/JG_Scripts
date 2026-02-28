-- @description Sort items to tracks by prefix and lane
-- @author JG
-- @version 1.0.0
-- @about
--   Sorts selected items to tracks based on a 3-digit prefix in the take name.
--   It also assigns them to specific track lanes based on a "T001", "T002", etc., suffix.

function Msg(text)
    reaper.ShowConsoleMsg(tostring(text) .. "\n")
end

function ExtractPrefix(name)
    -- Extract first 3 digits from name
    local prefix = string.match(name, "^(%d%d%d)")
    return prefix
end

function ExtractLaneSuffix(name)
    -- Extract T001, T002 etc. from name (before file extension)
    local lane = string.match(name, "T(%d+)")  -- Removed the $ anchor
    return lane
end

function FindTrackByPrefix(prefix)
    -- Find track whose name starts with the given prefix
    local trackCount = reaper.CountTracks(0)
    for i = 0, trackCount - 1 do
        local track = reaper.GetTrack(0, i)
        local _, trackName = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
        
        local trackPrefix = ExtractPrefix(trackName)
        if trackPrefix == prefix then
            return track
        end
    end
    return nil
end

function Main()
    reaper.Undo_BeginBlock()
    
    local itemCount = reaper.CountSelectedMediaItems(0)
    if itemCount == 0 then
        reaper.ShowMessageBox("No items selected!", "Error", 0)
        return
    end
    
    local movedCount = 0
    local notFoundCount = 0
    local errorItems = {}
    
    for i = 0, itemCount - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        local take = reaper.GetActiveTake(item)
        
        if take then
            local takeName = reaper.GetTakeName(take)
            local prefix = ExtractPrefix(takeName)
            
            if prefix then
                local targetTrack = FindTrackByPrefix(prefix)
                
                if targetTrack then
                    -- Move item to target track
                    reaper.MoveMediaItemToTrack(item, targetTrack)
                    
                    -- Set track lane based on T001, T002 suffix
                    local laneSuffix = ExtractLaneSuffix(takeName)
                    if laneSuffix then
                        local laneNumber = tonumber(laneSuffix) - 1  -- Lane 0-based
                        reaper.SetMediaItemInfo_Value(item, "I_FIXEDLANE", laneNumber)
                        Msg(string.format("Moved: %s -> Lane %d (T%s)", takeName, laneNumber + 1, laneSuffix))
                    else
                        -- No lane suffix, set to lane 0
                        reaper.SetMediaItemInfo_Value(item, "I_FIXEDLANE", 0)
                        Msg(string.format("Moved: %s -> Lane 1 (no T-suffix found)", takeName))
                    end
                    
                    movedCount = movedCount + 1
                else
                    notFoundCount = notFoundCount + 1
                    table.insert(errorItems, prefix .. " - " .. takeName)
                end
            else
                notFoundCount = notFoundCount + 1
                table.insert(errorItems, "No Prefix - " .. takeName)
            end
        end
    end
    
    -- Report results
    local message = string.format("%d Items sorted", movedCount)
    if notFoundCount > 0 then
        message = message .. string.format("\n%d Items could not be sorted:", notFoundCount)
        for i, errItem in ipairs(errorItems) do
            if i <= 10 then  -- Show max 10 errors
                message = message .. "\n  - " .. errItem
            end
        end
        if #errorItems > 10 then
            message = message .. string.format("\n  ... and %d more", #errorItems - 10)
        end
    end
    
    reaper.ShowMessageBox(message, "Sorting complete", 0)
    
    reaper.Undo_EndBlock("Sort items by take name prefix", -1)
    reaper.UpdateArrange()
end

reaper.PreventUIRefresh(1)
Main()
reaper.PreventUIRefresh(-1)