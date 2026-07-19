-- @description Smart Insert Track (insert track or folder for selection)
-- @author JG
-- @version 1.2.1
-- @changelog
--   Pair base-name suggestion keeps the original casing (no reformatting).
-- @about
--   Inserts a new track like action 40001. If multiple tracks are selected,
--   offers to create a folder track containing the selected tracks instead.

-- Suffix pairs that suggest a dual-mono / stereo pair.
-- directional: the suffix says which side (first entry = left).
-- positional (directional=false): suffixes carry no side info -> the upper
-- track (first in the TCP) pans left, the lower one right.
local PAIR_SUFFIXES = {
    { "l",     "r",      directional = true },
    { "left",  "right",  directional = true },
    { "links", "rechts", directional = true },
    { "li",    "re",     directional = true },
    { "lo",    "hi",     directional = false },
    { "low",   "high",   directional = false },
    { "lower", "upper",  directional = false },
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

-- Instrument groups for folder-name suggestions. If every selected track
-- matches the same group, its name (in caps) is suggested.
local GROUPS = {
    { name = "DRUMS",   words = { kick=1, bd=1, bassdrum=1, snare=1, sn=1, tom=1, toms=1, floor=1,
                                  floortom=1, hh=1, hihat=1, hihats=1, hat=1, hats=1, oh=1, ohs=1,
                                  overhead=1, overheads=1, ride=1, crash=1, cymbal=1, cymbals=1,
                                  room=1, drum=1, drums=1, schlagzeug=1 } },
    { name = "PERC",    words = { perc=1, percussion=1, shaker=1, tambourine=1, tamb=1, conga=1,
                                  congas=1, bongo=1, bongos=1, clap=1, claps=1, cowbell=1, cajon=1,
                                  timbale=1, timbales=1 } },
    { name = "KEYS",    words = { piano=1, klavier=1, keys=1, keyboard=1, rhodes=1, wurli=1,
                                  wurlitzer=1, organ=1, orgel=1, hammond=1, synth=1, synths=1,
                                  pad=1, pads=1, clav=1, ep=1 } },
    { name = "GUITARS", words = { guitar=1, guitars=1, gtr=1, gtrs=1, git=1, gitarre=1, gitarren=1,
                                  acoustic=1, akustik=1, western=1 } },
    { name = "BASS",    words = { bass=1, synthbass=1, subbass=1 } },
    { name = "VOCALS",  words = { vox=1, vocal=1, vocals=1, voc=1, gesang=1, bgv=1, bgvs=1,
                                  choir=1, chor=1, harmony=1, harmonies=1 } },
    { name = "STRINGS", words = { strings=1, streicher=1, violin=1, violins=1, vln=1, viola=1,
                                  vla=1, cello=1, celli=1, vc=1 } },
    { name = "HORNS",   words = { brass=1, blaeser=1, horn=1, horns=1, trumpet=1, tpt=1,
                                  trombone=1, tbn=1, sax=1, saxophone=1, tuba=1 } },
}

local function track_matches_group(name, words)
    for token in name:lower():gmatch("%a+") do
        if words[token] then return true end
    end
    return false
end

-- Return the group name (caps) if ALL names match the same group, else nil.
local function detect_group(names)
    for _, group in ipairs(GROUPS) do
        local all = true
        for _, name in ipairs(names) do
            if not track_matches_group(name, group.words) then all = false break end
        end
        if all then return group.name end
    end
    return nil
end

-- If the two names form a recognized pair, return the left track index (1 or 2).
-- Names are passed in track order (1 = upper track in the TCP).
local function detect_lr_pair(name1, name2)
    local base1, suf1 = split_suffix(name1)
    local base2, suf2 = split_suffix(name2)
    if base1 ~= base2 then return nil end
    for _, pair in ipairs(PAIR_SUFFIXES) do
        if (suf1 == pair[1] and suf2 == pair[2]) or
           (suf1 == pair[2] and suf2 == pair[1]) then
            if not pair.directional then return 1 end -- upper track pans left
            return (suf1 == pair[1]) and 1 or 2
        end
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

    -- Collect selected tracks (pointers stay valid across insertion) and names
    local sel_tracks, sel_names = {}, {}
    for i = 0, sel_count - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
        sel_tracks[#sel_tracks + 1] = track
        sel_names[#sel_names + 1] = name
    end

    -- Stereo-pair detection (exactly two tracks)
    local left_idx = (sel_count == 2) and detect_lr_pair(sel_names[1], sel_names[2]) or nil

    -- Folder name suggestion: pair base name, else common instrument group
    local suggestion = ""
    if left_idx then
        local base = sel_names[1]:match("^(.-)[%s%._%-/]+[^%s%._%-/]+$") or ""
        suggestion = base:gsub("^%s+", ""):gsub("[%s%._%-/]+$", "")
    end
    if suggestion == "" then
        suggestion = detect_group(sel_names) or ""
    end
    suggestion = suggestion:gsub(",", "") -- commas would break the CSV field

    -- Ask for the folder name (cancel = create unnamed folder)
    local name_ok, folder_name = reaper.GetUserInputs(
        "Smart Insert Track", 1, "Folder track name:,extrawidth=120", suggestion
    )
    if not name_ok then folder_name = "" end

    -- Exactly two tracks with stereo-pair suffixes: offer L/R panning
    local left_track, right_track
    if sel_count == 2 then
        local name1, name2 = sel_names[1], sel_names[2]
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
