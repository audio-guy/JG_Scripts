-- @description Group Color Manager
-- @author JG
-- @version 1.0.0
-- @about
--   Automatically colors tracks based on their active edit groups.
--   Uses group ribbon colors and restores original colors when groups are bypassed.

local script_name = "Group Color Manager"
local ext_state_section = "GroupColorManager"
local debug_output = true  -- ENABLE DEBUG to see what's happening

-- Check if script should continue running
function ShouldStop()
    local command_id = reaper.NamedCommandLookup("_RS6e8b8c4b6c8d4e9f8a7b6c5d4e3f2a1b")  -- Dummy ID for termination check
    return reaper.GetExtState(ext_state_section, "stop") == "1"
end

-- Get the color of a specific group's ribbon
function GetGroupRibbonColor(group_idx)
    -- Predefined color scheme that matches Reaper's group ribbons
    local group_colors = {
        0xFF6B6B, -- Group 1: Red
        0x4ECDC4, -- Group 2: Teal
        0x45B7D1, -- Group 3: Blue
        0xF7DC6F, -- Group 4: Yellow
        0xBB8FCE, -- Group 5: Purple
        0x52C77A, -- Group 6: Green
        0xFF8A5B, -- Group 7: Orange
        0xF8B739, -- Group 8: Gold
        0x00CEC9, -- Group 9: Cyan
        0xFD79A8, -- Group 10: Pink
        0x74B9FF, -- Group 11: Light Blue
        0xA29BFE, -- Group 12: Lavender
        0x55EFC4, -- Group 13: Mint
        0xFAB1A0, -- Group 14: Peach
        0xDFE6E9, -- Group 15: Gray
        0xFECE5A, -- Group 16: Amber
        0xFF7675, -- Group 17: Light Red
        0x81ECEC, -- Group 18: Aqua
        0xA29BFE, -- Group 19: Periwinkle
        0xFFD93D, -- Group 20: Bright Yellow
        0x6C5CE7, -- Group 21: Indigo
        0xFD79A8, -- Group 22: Rose
        0x00B894, -- Group 23: Sea Green
        0xE17055, -- Group 24: Terra Cotta
        0x74B9FF, -- Group 25: Sky Blue
        0xA29BFE, -- Group 26: Lilac
        0xFDCB6E, -- Group 27: Mustard
        0xE84393, -- Group 28: Magenta
        0x00CEC9, -- Group 29: Turquoise
        0xD63031, -- Group 30: Dark Red
        0x0984E3, -- Group 31: Ocean Blue
        0x6C5CE7, -- Group 32: Deep Purple
    }
    
    -- Add native color flag to ensure proper color display
    local color = group_colors[group_idx + 1] or 0x808080
    return color | 0x1000000
end

-- Save original track color (only if not already managed by this script)
function SaveOriginalColor(track)
    -- Check if we already have an original color saved
    local saved = reaper.GetSetMediaTrackInfo_String(track, "P_EXT:" .. ext_state_section .. "_original", "", false)
    
    if saved == "" then
        -- No original color saved yet, save current BEFORE we change it
        local current_color = reaper.GetTrackColor(track)
        reaper.GetSetMediaTrackInfo_String(track, "P_EXT:" .. ext_state_section .. "_original", tostring(current_color), true)
        
        if debug_output then
            local track_name = ({reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)})[2]
            reaper.ShowConsoleMsg("    Saved original color for '" .. track_name .. "': " .. current_color .. "\n")
        end
    end
end

-- Restore original track color (DON'T clear it, keep it for next time)
function RestoreOriginalColor(track)
    local saved = reaper.GetSetMediaTrackInfo_String(track, "P_EXT:" .. ext_state_section .. "_original", "", false)
    
    if saved ~= "" then
        local original_color = tonumber(saved)
        if original_color then
            if debug_output then
                local track_name = ({reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)})[2]
                reaper.ShowConsoleMsg("    Restoring color for '" .. track_name .. "': " .. original_color .. "\n")
            end
            reaper.SetTrackColor(track, original_color)
            -- DON'T clear the saved color - keep it for the next group activation
        end
    end
end

-- Clear all saved original colors (for reset)
function ClearAllSavedColors()
    local track_count = reaper.CountTracks(0)
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        reaper.GetSetMediaTrackInfo_String(track, "P_EXT:" .. ext_state_section .. "_original", "", true)
    end
    reaper.ShowConsoleMsg("All saved colors cleared\n")
end

-- Check if track grouping is globally enabled
function IsGroupingEnabled()
    -- Check the toggle state of "Options: Enable item grouping"
    local item_grouping_state = reaper.GetToggleCommandState(40774)  -- Toggle item grouping
    
    -- Check the toggle state of "Options: Track media/razor edit grouping enabled"
    local media_grouping_state = reaper.GetToggleCommandState(41156)  -- Toggle media/razor edit grouping
    
    if debug_output then
        reaper.ShowConsoleMsg("Item grouping: " .. item_grouping_state .. ", Media grouping: " .. media_grouping_state .. "\n")
    end
    
    -- Return true if media/razor edit grouping is enabled
    return media_grouping_state == 1
end

-- Get all active groups for a track (checking MEDIA_EDIT_LEAD for edit groups)
-- This checks if groups are actually ACTIVE (not bypassed)
function GetActiveGroups(track)
    local active_groups = {}
    
    -- First check if grouping is globally enabled
    if not IsGroupingEnabled() then
        if debug_output then
            reaper.ShowConsoleMsg("  [Grouping globally DISABLED] ")
        end
        return active_groups  -- Return empty if grouping is disabled
    end
    
    -- MEDIA_EDIT_LEAD is what's used for track edit groups
    local membership = reaper.GetSetTrackGroupMembership(track, "MEDIA_EDIT_LEAD", 0, 0)
    
    if membership == 0 then
        return active_groups  -- No groups at all
    end
    
    -- Check which groups this track belongs to
    for group_idx = 0, 31 do
        if membership & (1 << group_idx) ~= 0 then
            table.insert(active_groups, group_idx)
        end
    end
    
    return active_groups
end

-- Get all tracks that belong to a specific group
function GetTracksInGroup(group_idx)
    local tracks_in_group = {}
    local track_count = reaper.CountTracks(0)
    
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        local groups = GetActiveGroups(track)
        
        for _, g in ipairs(groups) do
            if g == group_idx then
                table.insert(tracks_in_group, track)
                break
            end
        end
    end
    
    return tracks_in_group
end

-- Check if group A is a superset of group B (all tracks in B are also in A)
function IsSuperset(group_a, group_b)
    if group_a == group_b then
        return false  -- Same group is not a superset
    end
    
    local tracks_a = GetTracksInGroup(group_a)
    local tracks_b = GetTracksInGroup(group_b)
    
    if #tracks_b == 0 then
        return false
    end
    
    -- Create lookup table for group A
    local lookup_a = {}
    for _, track in ipairs(tracks_a) do
        local guid = reaper.GetTrackGUID(track)
        lookup_a[guid] = true
    end
    
    -- Check if all tracks from B are in A
    for _, track in ipairs(tracks_b) do
        local guid = reaper.GetTrackGUID(track)
        if not lookup_a[guid] then
            return false
        end
    end
    
    return true
end

-- Determine which group should be used for coloring
-- Returns: group_idx or "conflict" or nil
function GetColorGroup(track)
    local active_groups = GetActiveGroups(track)
    
    if #active_groups == 0 then
        return nil
    end
    
    if #active_groups == 1 then
        return active_groups[1]
    end
    
    -- Multiple groups - check for hierarchy
    -- Sort by priority (lower number = higher priority)
    table.sort(active_groups)
    
    -- Check if the highest priority group contains ALL other groups completely
    local highest_priority = active_groups[1]
    local is_hierarchical = true
    
    for i = 2, #active_groups do
        if not IsSuperset(highest_priority, active_groups[i]) then
            -- Not a clean hierarchy - we have a conflict
            is_hierarchical = false
            break
        end
    end
    
    if is_hierarchical then
        return highest_priority
    else
        -- Check if ANY lower priority group could work
        for i = 2, #active_groups do
            local can_be_parent = true
            for j = i + 1, #active_groups do
                if not IsSuperset(active_groups[i], active_groups[j]) then
                    can_be_parent = false
                    break
                end
            end
            if can_be_parent then
                return active_groups[i]
            end
        end
        
        return "conflict"
    end
end

-- Track the last state to only update when groups change
local last_track_states = {}
local script_just_started = true

-- Get a state key for a track based on its active groups
function GetTrackStateKey(track)
    local groups = GetActiveGroups(track)
    table.sort(groups)
    return table.concat(groups, ",")
end

-- Main processing function
function ProcessTracks()
    local track_count = reaper.CountTracks(0)
    
    if debug_output and script_just_started then
        reaper.ShowConsoleMsg("\n=== INITIAL Processing " .. track_count .. " tracks ===\n")
    end
    
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        local track_guid = reaper.GetTrackGUID(track)
        local active_groups = GetActiveGroups(track)
        local track_name = ({reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)})[2]
        
        -- Check if group state has changed for this track
        local current_state = GetTrackStateKey(track)
        local last_state = last_track_states[track_guid]
        
        -- On first run, just store the current state without changing colors
        if script_just_started then
            last_track_states[track_guid] = current_state
            
            -- If track has NO active groups on startup, save its current color as original
            if #active_groups == 0 then
                local saved = reaper.GetSetMediaTrackInfo_String(track, "P_EXT:" .. ext_state_section .. "_original", "", false)
                if saved == "" then
                    local current_color = reaper.GetTrackColor(track)
                    reaper.GetSetMediaTrackInfo_String(track, "P_EXT:" .. ext_state_section .. "_original", tostring(current_color), true)
                    if debug_output then
                        reaper.ShowConsoleMsg("Track '" .. track_name .. "' has no groups - saved color " .. current_color .. " as original\n")
                    end
                end
            end
        elseif current_state ~= last_state then
            -- State changed AFTER startup, process this track
            if debug_output then
                reaper.ShowConsoleMsg("Track " .. (i+1) .. " '" .. track_name .. "': ")
                if #active_groups == 0 then
                    reaper.ShowConsoleMsg("No groups")
                else
                    reaper.ShowConsoleMsg("Groups: ")
                    for _, g in ipairs(active_groups) do
                        reaper.ShowConsoleMsg((g+1) .. " ")
                    end
                end
            end
            
            local color_group = GetColorGroup(track)
            
            if color_group == "conflict" then
                -- Track is in conflicting groups - use warning color
                SaveOriginalColor(track)
                local warning_color = 16711680 | 16777216  -- Bright red
                
                if debug_output then
                    reaper.ShowConsoleMsg(" -> CONFLICT!\n")
                end
                
                reaper.SetTrackColor(track, warning_color)
            elseif color_group ~= nil then
                -- Track has a clear hierarchical group
                SaveOriginalColor(track)
                local group_color = GetGroupRibbonColor(color_group)
                
                if debug_output then
                    reaper.ShowConsoleMsg(" -> Use Group " .. (color_group+1) .. " color\n")
                end
                
                reaper.SetTrackColor(track, group_color)
            else
                -- No active group, restore original color
                if debug_output then
                    reaper.ShowConsoleMsg(" -> Restore original\n")
                end
                RestoreOriginalColor(track)
            end
            
            -- Update the state
            last_track_states[track_guid] = current_state
        end
    end
    
    if script_just_started then
        script_just_started = false
        if debug_output then
            reaper.ShowConsoleMsg("=== Initial state captured, now monitoring for changes ===\n\n")
        end
    end
end

-- Main loop
function Main()
    if ShouldStop() then
        reaper.ShowConsoleMsg("Group Color Manager stopped\n")
        -- Restore all colors before exiting
        for i = 0, reaper.CountTracks(0) - 1 do
            RestoreOriginalColor(reaper.GetTrack(0, i))
        end
        reaper.SetExtState(ext_state_section, "stop", "0", false)
        return
    end
    
    ProcessTracks()
    reaper.defer(Main)
end

-- Cleanup function
function Cleanup()
    reaper.ShowConsoleMsg("Group Color Manager cleaning up...\n")
    -- Restore all colors
    for i = 0, reaper.CountTracks(0) - 1 do
        RestoreOriginalColor(reaper.GetTrack(0, i))
    end
end

-- Debug: Show console on start
reaper.ShowConsoleMsg("Group Color Manager started\n")
reaper.ShowConsoleMsg("Script will capture current state and only react to GROUP CHANGES\n")

-- DON'T clear saved colors on startup - we need them!
-- ClearAllSavedColors()

-- Start the script
reaper.atexit(Cleanup)
Main()