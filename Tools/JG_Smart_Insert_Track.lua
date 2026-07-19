-- @description Smart Insert Track (insert track or folder for selection)
-- @author JG
-- @version 1.1.0
-- @changelog
--   Ask for the folder track name on creation.
--   Detect stereo-pair suffixes (L/R, Left/Right, Hi/Lo, ...) on exactly two
--   tracks and offer to pan them hard left/right.
-- @about
--   Inserts a new track like action 40001. If multiple tracks are selected,
--   offers to create a folder track containing the selected tracks instead.

-- Suffix pairs that suggest a dual-mono / stereo pair.
-- First entry pans left, second pans right.
local PAIR_SUFFIXES = {
    { "l",     "r" },
    { "left",  "right" },
    { "links", "rechts" },
    { "li",    "re" },
    { "lo",    "hi" },
    { "low",   "high" },
    { "lower", "upper" },
}

-- Split a track name into (base, suffix-token). The suffix is the last token
-- separated by space / dot / underscore / dash / slash, with optional
-- surrounding brackets, e.g. "Overhead (L)" -> "overhead", "l".
local function split_suffix(name)
    name = name:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local base, suffix = name:match("^(.-)[%s%._%-/]+([^%s%._%-/]+)$")
    if not base then
        -- Name is a single token ("L" / "R" as the whole name)
        base, suffix = "", name
    end
    suffix = suffix:gsub("^[%(%[]+", ""):gsub("[%)%]]+$", "")
    base = base:gsub("[%s%._%-/]+$", "")
    return base, suffix
end

-- If the two names form a recognized pair, return the left track index (1 or 2).
local function detect_lr_pair(name1, name2)
    local base1, suf1 = split_suffix(name1)
    local base2, suf2 = split_suffix(name2)
    if base1 ~= base2 then return nil end
    for _, pair in ipairs(PAIR_SUFFIXES) do
        if suf1 == pair[1] and suf2 == pair[2] then return 1 end
        if suf1 == pair[2] and suf2 == pair[1] then return 2 end
    end
    return nil
end

function main()
    local sel_count = reaper.CountSelectedTracks(0)

    -- 0 or 1 track selected: just insert new track
    if sel_count <= 1 then
        reaper.Main_OnCommand(40001, 0) -- Insert new track
        return
    end

    -- Multiple tracks selected: ask about folder
    local ret = reaper.MB(
        "Create a folder track for the " .. sel_count .. " selected tracks?\n\n(Cancel = insert normal track)",
        "Smart Insert Track",
        1 -- OK / Cancel
    )

    -- Cancel (2) or closed (0): just insert new track
    if ret ~= 1 then
        reaper.Main_OnCommand(40001, 0)
        return
    end

    -- Collect selected tracks (pointers stay valid across insertion)
    local sel_tracks = {}
    for i = 0, sel_count - 1 do
        sel_tracks[#sel_tracks + 1] = reaper.GetSelectedTrack(0, i)
    end

    -- Ask for the folder name (cancel = create unnamed folder)
    local name_ok, folder_name = reaper.GetUserInputs(
        "Smart Insert Track", 1, "Folder track name:,extrawidth=120", ""
    )
    if not name_ok then folder_name = "" end

    -- Exactly two tracks with stereo-pair suffixes: offer L/R panning
    local left_track, right_track
    if sel_count == 2 then
        local _, name1 = reaper.GetSetMediaTrackInfo_String(sel_tracks[1], "P_NAME", "", false)
        local _, name2 = reaper.GetSetMediaTrackInfo_String(sel_tracks[2], "P_NAME", "", false)
        local left_idx = detect_lr_pair(name1, name2)
        if left_idx then
            local l_name = (left_idx == 1) and name1 or name2
            local r_name = (left_idx == 1) and name2 or name1
            local pan_ret = reaper.MB(
                'These look like a stereo pair. Pan them hard L/R?\n\n' ..
                '"' .. l_name .. '"  ->  100% L\n' ..
                '"' .. r_name .. '"  ->  100% R',
                "Smart Insert Track", 4 -- Yes / No
            )
            if pan_ret == 6 then -- Yes
                left_track  = sel_tracks[left_idx]
                right_track = sel_tracks[left_idx == 1 and 2 or 1]
            end
        end
    end

    -- Create folder track for selected tracks
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    -- Find first and last selected track indices (0-based)
    local first_idx = math.huge
    local last_idx = -1

    for _, track in ipairs(sel_tracks) do
        local idx = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) - 1
        if idx < first_idx then first_idx = idx end
        if idx > last_idx then last_idx = idx end
    end

    -- Insert new track above the first selected track
    reaper.InsertTrackAtIndex(first_idx, true)
    local folder_track = reaper.GetTrack(0, first_idx)

    if folder_name ~= "" then
        reaper.GetSetMediaTrackInfo_String(folder_track, "P_NAME", folder_name, true)
    end

    -- Set as folder parent
    reaper.SetMediaTrackInfo_Value(folder_track, "I_FOLDERDEPTH", 1)

    -- Close folder on the last selected track (shifted by +1 due to insertion)
    local last_track = reaper.GetTrack(0, last_idx + 1)
    local cur_depth = reaper.GetMediaTrackInfo_Value(last_track, "I_FOLDERDEPTH")
    reaper.SetMediaTrackInfo_Value(last_track, "I_FOLDERDEPTH", cur_depth - 1)

    -- Apply L/R panning if confirmed
    if left_track then
        reaper.SetMediaTrackInfo_Value(left_track, "D_PAN", -1)
        reaper.SetMediaTrackInfo_Value(right_track, "D_PAN", 1)
    end

    -- Select only the new folder track
    reaper.SetOnlyTrackSelected(folder_track)

    reaper.PreventUIRefresh(-1)
    reaper.TrackList_AdjustWindows(false)
    reaper.Undo_EndBlock("Smart Insert Track: Create folder", -1)
end

main()
