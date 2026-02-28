-- @description Recording Scheduler
-- @author Julius Gass
-- @version 1.0.0
-- @about
--   Schedule automatic recordings with start/stop times.
--   Supports multiple slots, overlap detection, merge/replace/adjust options,
--   countdown display and seamless back-to-back recordings.
--   Requires SWS Extension and ReaImGui.

local reaper = reaper
local ctx = reaper.ImGui_CreateContext('Recording Scheduler')
local FONT = reaper.ImGui_CreateFont('sans-serif', 14)
reaper.ImGui_Attach(ctx, FONT)

-- Colors (ImGui uses RGBA in hex: 0xRRGGBBAA format for TextColored)
local COLOR_CONFLICT    = 0xFF2222FF  
local COLOR_RUNNING     = 0xFF2222FF  
local COLOR_WAITING     = 0xAAAAAAFF  
local COLOR_FINISHED    = 0x22FF22FF  

-- State
local slots = {}
local input_date, input_start, input_end, input_name = "", "", "", ""
local edit_index, focus_field = nil, "start"
local recording, countdown_enabled = false, false
local recording_stop_time, marker_ids = nil, {}
local overlap_pending, overlap_newslot, overlap_oldslot, overlap_oldindex = false, nil, nil, nil
local base_day = nil
local last_check_time = 0
local recording_limit_popup = false
local close_warning_popup = false
local show_finished = false  -- Default: hide finished recordings

-- ---------- Time mapping ----------
local function to_project_pos(unix_time)
  local t = os.date("*t", unix_time)
  local day_start = os.time{year=t.year, month=t.month, day=t.day, hour=0, min=0, sec=0}
  if not base_day then base_day = day_start end
  local day_index = math.floor((day_start - base_day) / 86400 + 0.000001)
  local sec_of_day = t.hour*3600 + t.min*60 + t.sec
  return day_index*86400 + sec_of_day
end

-- ---------- Parsing ----------
local function parse_start_field(date_str, time_str)
  if not date_str or not time_str or date_str == "" or time_str == "" then return nil end
  local y,m,d = date_str:match("^(%d%d)(%d%d)(%d%d)$")
  local hh,mm = time_str:match("^(%d%d)(%d%d)$")
  if not y or not m or not d or not hh or not mm then return nil end
  return os.time{year=2000+tonumber(y), month=tonumber(m), day=tonumber(d), hour=tonumber(hh), min=tonumber(mm), sec=0}
end

local function parse_end_field(start_sec, end_str)
  if not end_str or end_str == "" then return nil end
  local hh,mm = end_str:match("^(%d%d)(%d%d)$")
  if not hh or not mm then return nil end
  local dt = os.date("*t", start_sec)
  local t = os.time{year=dt.year, month=dt.month, day=dt.day, hour=tonumber(hh), min=tonumber(mm), sec=0}
  if t < start_sec then t = t + 24*3600 end
  return t
end

local function sec_to_hhmm(sec)   return os.date("%H%M", sec) end

-- ---------- Markers ----------
local function add_marker(slot, actual_start_time)
  local marker_time = actual_start_time or slot.start_sec
  local pos = to_project_pos(marker_time)
  local name = os.date("%y%m%d", marker_time).." - "
             ..sec_to_hhmm(marker_time).."-"
             ..(slot.end_sec and sec_to_hhmm(slot.end_sec) or "OPEN")
             .." "..slot.name
  local id = reaper.AddProjectMarker2(0, false, pos, 0, name, -1, 0)
  marker_ids[slot] = id
end

local function remove_marker(slot)
  local id = marker_ids[slot]
  if id then reaper.DeleteProjectMarker(0, id, false) end
  marker_ids[slot] = nil
end

-- ---------- Overlap ----------
local function check_overlap(new_slot, ignore_index)
  for i, s in ipairs(slots) do
    if i ~= ignore_index then
      local new_end = new_slot.end_sec or math.huge
      local s_end = s.end_sec or math.huge
      if new_slot.start_sec < s_end and new_end > s.start_sec then
        return i, s
      end
    end
  end
  return nil
end

-- ---------- Recording Mode Check ----------
local function check_and_fix_recording_mode()
  local rec_mode = reaper.GetSetProjectInfo(0, "PROJECT_RECMODE", -1, false)
  if rec_mode ~= 0 then
    reaper.GetSetProjectInfo(0, "PROJECT_RECMODE", 0, true)
  end
  local rec_path_str = reaper.GetProjectPath("")
  if rec_path_str == "" then
    rec_path_str = reaper.GetResourcePath().."/Data"
  end
  return rec_mode, rec_path_str
end

local armed_tracks = 0

-- ---------- Recording Limit Check ----------
local function check_and_remove_recording_limit()
  local limit = reaper.SNM_GetDoubleConfigVar("projreclen", -1)
  if limit > 0 then
    reaper.SNM_SetDoubleConfigVar("projreclen", 0)
    recording_limit_popup = true
    return true
  end
  return false
end

-- ---------- Recording Limit Popup ----------
local function draw_recording_limit_popup()
  if not recording_limit_popup then return end
  
  local visible = reaper.ImGui_Begin(ctx, "Recording Limit Removed", true,
    reaper.ImGui_WindowFlags_AlwaysAutoResize() | reaper.ImGui_WindowFlags_NoCollapse())

  if visible then
    reaper.ImGui_Text(ctx, "📢 Info: Recording limit was removed from project settings")
    reaper.ImGui_Text(ctx, "to allow scheduled recordings to work properly.")
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Text(ctx, "You can re-enable it later in Project Settings > Media")
    
    if reaper.ImGui_Button(ctx, "OK", -1, 0) then
      recording_limit_popup = false
    end
  end
  reaper.ImGui_End(ctx)
end

-- ---------- Close Warning Popup ----------
local function draw_close_warning_popup()
  if not close_warning_popup then return false end
  
  local visible = reaper.ImGui_Begin(ctx, "Close Warning", true,
    reaper.ImGui_WindowFlags_AlwaysAutoResize() | reaper.ImGui_WindowFlags_NoCollapse())

  if visible then
    reaper.ImGui_Text(ctx, "⚠️ You have scheduled recordings!")
    reaper.ImGui_Separator(ctx)
    
    local waiting_count = 0
    local active_count = 0
    local now_sec = os.time()
    
    for _, slot in ipairs(slots) do
      if slot.active then
        active_count = active_count + 1
      elseif now_sec < slot.start_sec or (slot.end_sec and now_sec < slot.end_sec) then
        waiting_count = waiting_count + 1
      end
    end
    
    if active_count > 0 then
      reaper.ImGui_Text(ctx, "• "..active_count.." recording(s) currently active")
    end
    if waiting_count > 0 then
      reaper.ImGui_Text(ctx, "• "..waiting_count.." recording(s) scheduled")
    end
    
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Text(ctx, "Closing will cancel all scheduled recordings!")
    
    local should_close = false
    if reaper.ImGui_Button(ctx, "Close Anyway", 120, 0) then
      close_warning_popup = false
      should_close = true
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Keep Open", 120, 0) then
      close_warning_popup = false
    end
    
    reaper.ImGui_End(ctx)
    return should_close
  end
  
  reaper.ImGui_End(ctx)
  return false
end

-- ---------- Overlap Dialog ----------
local function draw_overlap_dialog()
  if not overlap_pending then return end
  local visible = reaper.ImGui_Begin(ctx, "Overlap Conflict", true,
    reaper.ImGui_WindowFlags_AlwaysAutoResize())

  if visible then
    reaper.ImGui_Text(ctx, "Overlap detected between slots:")

    local function draw_slot(label, slot, conflict_other)
      reaper.ImGui_Text(ctx, label.." "..slot.date.." ")
      reaper.ImGui_SameLine(ctx, 0, 0)
      
      if label == "Old:" and conflict_other and slot.end_sec and slot.end_sec > conflict_other.start_sec then
        reaper.ImGui_Text(ctx, sec_to_hhmm(slot.start_sec).." - ")
        reaper.ImGui_SameLine(ctx, 0, 0)
        reaper.ImGui_TextColored(ctx, COLOR_CONFLICT, sec_to_hhmm(slot.end_sec))
      elseif label == "New:" and conflict_other and conflict_other.end_sec and slot.start_sec < conflict_other.end_sec then
        reaper.ImGui_TextColored(ctx, COLOR_CONFLICT, sec_to_hhmm(slot.start_sec))
        reaper.ImGui_SameLine(ctx, 0, 0)
        reaper.ImGui_Text(ctx, " - "..(slot.end_sec and sec_to_hhmm(slot.end_sec) or "OPEN"))
      else
        reaper.ImGui_Text(ctx, sec_to_hhmm(slot.start_sec).." - "..(slot.end_sec and sec_to_hhmm(slot.end_sec) or "OPEN"))
      end
    end

    draw_slot("Old:", overlap_oldslot, overlap_newslot)
    draw_slot("New:", overlap_newslot, overlap_oldslot)

    if reaper.ImGui_Button(ctx, "Merge") then
      local old_index = overlap_oldindex
      overlap_oldslot.start_sec = math.min(overlap_oldslot.start_sec, overlap_newslot.start_sec)
      overlap_oldslot.end_sec   = math.max(overlap_oldslot.end_sec or 0, overlap_newslot.end_sec or 0)
      
      if old_index then
        slots[old_index] = overlap_oldslot
        -- Update recording stop time if this slot is currently active
        if overlap_oldslot.active then
          recording_stop_time = overlap_oldslot.end_sec
          countdown_enabled = (overlap_oldslot.end_sec ~= nil)
        end
      end
      
      overlap_pending = false
      overlap_oldindex = nil
      input_start, input_end, input_name = "", "", ""
      focus_field = "start"
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Trim") then
      local old_index = overlap_oldindex
      overlap_oldslot.end_sec = overlap_newslot.start_sec
      
      if old_index then
        slots[old_index] = overlap_oldslot
        -- Update recording stop time if this slot is currently active
        if overlap_oldslot.active then
          recording_stop_time = overlap_oldslot.end_sec
          countdown_enabled = (overlap_oldslot.end_sec ~= nil)
        end
      end
      
      table.insert(slots, overlap_newslot)
      overlap_pending = false
      overlap_oldindex = nil
      input_start, input_end, input_name = "", "", ""
      focus_field = "start"
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Cancel") then
      overlap_pending = false
      input_start, input_end, input_name = "", "", ""
      focus_field = "start"
    end
  end
  reaper.ImGui_End(ctx)
end

-- ---------- Input Row ----------
local function draw_input_row()
  input_date  = input_date  or ""
  input_start = input_start or ""
  input_end   = input_end   or ""
  input_name  = input_name  or ""

  reaper.ImGui_TableNextRow(ctx)

  reaper.ImGui_TableNextColumn(ctx)
  if input_date == "" then input_date = os.date("%y%m%d") end
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  local rv, new_date = reaper.ImGui_InputTextWithHint(ctx, "##date", "YYMMDD", input_date, 0)
  if rv then input_date = new_date end

  reaper.ImGui_TableNextColumn(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  rv, new_start = reaper.ImGui_InputTextWithHint(ctx, "##start", "HHMM", input_start, reaper.ImGui_InputTextFlags_CharsDecimal())
  if rv then input_start = new_start end

  reaper.ImGui_TableNextColumn(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  rv, new_end = reaper.ImGui_InputTextWithHint(ctx, "##end", "HHMM", input_end, reaper.ImGui_InputTextFlags_CharsDecimal())
  if rv then input_end = new_end end

  reaper.ImGui_TableNextColumn(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  rv, new_name = reaper.ImGui_InputTextWithHint(ctx, "##name", "Name", input_name, 0)
  if rv then input_name = new_name end

  reaper.ImGui_TableNextColumn(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  
  local function commit_slot()
    local start = parse_start_field(input_date, input_start)
    if not start then return end
    local new_slot = {
      date      = input_date,
      start_sec = start,
      end_sec   = parse_end_field(start, input_end),
      name      = (input_name ~= "" and input_name) or "(unnamed)",
      active    = false
    }
    local ci, cslot = check_overlap(new_slot, edit_index)
    if cslot then
      overlap_pending, overlap_newslot, overlap_oldslot, overlap_oldindex = true, new_slot, cslot, ci
      return
    end
    if edit_index then 
      local old_slot = slots[edit_index]
      new_slot.active = old_slot.active
      if old_slot.active then
        -- Remove old marker and create new one with updated times
        remove_marker(old_slot)
        add_marker(new_slot, old_slot.start_sec or now_sec)
        -- Update recording stop time if this slot is currently recording
        recording_stop_time = new_slot.end_sec
        countdown_enabled = (new_slot.end_sec ~= nil)
      end
      slots[edit_index] = new_slot
      edit_index = nil 
    else 
      table.insert(slots, new_slot)
    end
    input_start, input_end, input_name = "", "", ""
    focus_field = "start"
  end

  local enter_pressed = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter()) or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter())
  
  if edit_index then
    if reaper.ImGui_Button(ctx, "Update Slot", -1, 0) or enter_pressed then 
      commit_slot() 
    end
    if reaper.ImGui_Button(ctx, "Delete Slot", -1, 0) then
      local slot_to_delete = slots[edit_index]
      if not slot_to_delete.active then
        remove_marker(slot_to_delete)
      end
      table.remove(slots, edit_index)
      input_start, input_end, input_name = "", "", ""
      edit_index = nil
      focus_field = "start"
    end
  else
    if reaper.ImGui_Button(ctx, "Add Slot", -1, 0) or enter_pressed then 
      commit_slot() 
    end
  end
end

-- ---------- Main ----------
local function Main()
  local visible, open = reaper.ImGui_Begin(ctx, 'Recording Scheduler', true)

  if visible then
    reaper.ImGui_PushFont(ctx, FONT, 14)
    local now_sec = os.time()
    
    armed_tracks = 0
    for t = 0, reaper.CountTracks(0) - 1 do
      local track = reaper.GetTrack(0, t)
      if reaper.GetMediaTrackInfo_Value(track, "I_RECARM") == 1 then
        armed_tracks = armed_tracks + 1
      end
    end

    local current_playstate = reaper.GetPlayState()
    local is_actually_recording = (current_playstate & 4 ~= 0)
    
    -- Check if recording was stopped manually
    if recording and not is_actually_recording then
      -- Recording stopped - determine if it was 40668 (discard) or normal stop
      local has_recorded_items = false
      
      for i = 0, reaper.CountMediaItems(0) - 1 do
        local item = reaper.GetMediaItem(0, i)
        local take = reaper.GetActiveTake(item)
        if take then
          local source = reaper.GetMediaItemTake_Source(take)
          if source then
            has_recorded_items = true
            break
          end
        end
      end
      
      if not has_recorded_items then
        -- 40668 detected - remove everything
        for i = #slots, 1, -1 do
          if slots[i].active then 
            remove_marker(slots[i])
            table.remove(slots, i)
          end
        end
      else
        -- Normal stop - keep marker, mark as finished
        for i = 1, #slots do
          if slots[i].active then 
            slots[i].active = false
            slots[i].manually_stopped = true
            break  -- Only one slot can be active at a time
          end
        end
      end
      
      recording, countdown_enabled, recording_stop_time = false, false, nil
      last_check_time = 0  -- Reset to allow immediate check for next slots
    end

    if recording and recording_stop_time and countdown_enabled and now_sec >= recording_stop_time then
      -- Check if there's another slot starting immediately after this one
      local next_slot_starts_now = false
      local next_slot = nil
      
      for _, slot in ipairs(slots) do
        if not slot.active and slot.start_sec == recording_stop_time then
          next_slot_starts_now = true
          next_slot = slot
          break
        end
      end
      
      -- Mark current slot as inactive BEFORE starting next one
      for i, slot in ipairs(slots) do
        if slot.active then 
          slot.active = false
          break
        end
      end
      
      if next_slot_starts_now then
        -- Use 40666 to start new file without gap - don't stop recording
        reaper.Main_OnCommand(40666, 0)
        
        -- Mark next slot as active and add marker
        if next_slot then
          add_marker(next_slot, now_sec)
          next_slot.active = true
          recording_stop_time = next_slot.end_sec
          countdown_enabled = (next_slot.end_sec ~= nil)
        end
      else
        -- Normal stop - no next slot
        reaper.Main_OnCommand(1016, 0)
        recording, countdown_enabled, recording_stop_time = false, false, nil
      end
    end

    if not recording and now_sec > last_check_time then
      last_check_time = now_sec
      
      for i, slot in ipairs(slots) do
        -- Skip slots that were manually stopped - this is the KEY check
        if slot.manually_stopped then
          goto continue
        end
        
        local should_start = now_sec >= slot.start_sec and (not slot.end_sec or now_sec < slot.end_sec)
        
        if should_start and not slot.active then
          check_and_remove_recording_limit()
          check_and_fix_recording_mode()
          
          local pos
          if now_sec > slot.start_sec then
            local elapsed = now_sec - slot.start_sec
            pos = to_project_pos(slot.start_sec) + elapsed
          else
            pos = to_project_pos(slot.start_sec)
          end
          
          reaper.SetEditCurPos(pos, true, false)
          reaper.UpdateArrange()
          reaper.CSurf_OnRecord()
          reaper.UpdateArrange()
          
          local new_playstate = reaper.GetPlayState()
          if new_playstate & 4 == 0 then
            reaper.Main_OnCommand(1013, 0)
            reaper.UpdateArrange()
          end
          
          add_marker(slot, now_sec)
          slot.active, recording = true, true
          recording_stop_time = slot.end_sec
          countdown_enabled = (slot.end_sec ~= nil)
          break
        end
        
        ::continue::
      end
    end

    table.sort(slots, function(a,b) return a.start_sec < b.start_sec end)
    
    if reaper.ImGui_Button(ctx, show_finished and "Hide Finished" or "Show Finished", 150, 0) then
      show_finished = not show_finished
    end
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_Text(ctx, "Armed tracks: "..armed_tracks)

    if reaper.ImGui_BeginTable(ctx, "SlotsTable", 5,
      reaper.ImGui_TableFlags_RowBg() | reaper.ImGui_TableFlags_Borders() | reaper.ImGui_TableFlags_Resizable()) then
      reaper.ImGui_TableSetupColumn(ctx, "Date", reaper.ImGui_TableColumnFlags_WidthFixed(), 80)
      reaper.ImGui_TableSetupColumn(ctx, "Start", reaper.ImGui_TableColumnFlags_WidthFixed(), 70)
      reaper.ImGui_TableSetupColumn(ctx, "End", reaper.ImGui_TableColumnFlags_WidthFixed(), 70)
      reaper.ImGui_TableSetupColumn(ctx, "Name", reaper.ImGui_TableColumnFlags_WidthStretch())
      reaper.ImGui_TableSetupColumn(ctx, "Status", reaper.ImGui_TableColumnFlags_WidthFixed(), 200)
      reaper.ImGui_TableHeadersRow(ctx)

      draw_input_row()

      for i, slot in ipairs(slots) do
        -- Check if finished (ended or manually stopped)
        local is_finished = slot.manually_stopped or (not slot.active and now_sec > (slot.end_sec or slot.start_sec + 3600))
        
        if not is_finished or show_finished then
          reaper.ImGui_TableNextRow(ctx)
          
          reaper.ImGui_TableNextColumn(ctx)
          local row_clicked = reaper.ImGui_Selectable(ctx, slot.date.."##"..i, false, reaper.ImGui_SelectableFlags_SpanAllColumns())
          if row_clicked then
            edit_index = i
            input_date = slot.date
            input_start = sec_to_hhmm(slot.start_sec)
            input_end = slot.end_sec and sec_to_hhmm(slot.end_sec) or ""
            input_name = slot.name
            focus_field = "start"
          end
          
          reaper.ImGui_TableNextColumn(ctx); reaper.ImGui_Text(ctx, sec_to_hhmm(slot.start_sec))
          reaper.ImGui_TableNextColumn(ctx); reaper.ImGui_Text(ctx, slot.end_sec and sec_to_hhmm(slot.end_sec) or "OPEN")
          reaper.ImGui_TableNextColumn(ctx); reaper.ImGui_Text(ctx, slot.name)
          
          reaper.ImGui_TableNextColumn(ctx)
          if slot.active then
            reaper.ImGui_TextColored(ctx, COLOR_RUNNING, "● RECORDING")
            if slot.end_sec then
              local remain = slot.end_sec - now_sec
              if remain > 0 then 
                reaper.ImGui_SameLine(ctx)
                local hours = math.floor(remain / 3600)
                local minutes = math.floor((remain % 3600) / 60)
                local seconds = remain % 60
                reaper.ImGui_Text(ctx, string.format("(%02d:%02d:%02d)", hours, minutes, seconds))
              end
            end
          elseif slot.manually_stopped or is_finished then
            reaper.ImGui_TextColored(ctx, COLOR_FINISHED, "● FINISHED")
          else
            reaper.ImGui_TextColored(ctx, COLOR_WAITING, "● WAITING")
            local time_to_start = slot.start_sec - now_sec
            if time_to_start > 0 then
              reaper.ImGui_SameLine(ctx)
              local hours = math.floor(time_to_start / 3600)
              local minutes = math.floor((time_to_start % 3600) / 60)
              local seconds = time_to_start % 60
              reaper.ImGui_Text(ctx, string.format("(%02d:%02d:%02d)", hours, minutes, seconds))
            end
          end
        end
      end
      reaper.ImGui_EndTable(ctx)
    end

    draw_overlap_dialog()
    draw_recording_limit_popup()
    
    local should_close = draw_close_warning_popup()
    if should_close then
      return  -- Exit immediately
    end

    reaper.ImGui_PopFont(ctx)
  end
  reaper.ImGui_End(ctx)

  if not open then 
    local has_active_or_scheduled = false
    local now_sec = os.time()
    
    for _, slot in ipairs(slots) do
      if slot.active or now_sec < slot.start_sec or (slot.end_sec and now_sec < slot.end_sec) then
        has_active_or_scheduled = true
        break
      end
    end
    
    if has_active_or_scheduled then
      close_warning_popup = true
      open = true  -- Keep window open and show warning
    else
      return  -- Close if no active/scheduled recordings
    end
  end
  reaper.defer(Main)
end

Main()
