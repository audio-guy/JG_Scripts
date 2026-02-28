-- @description Rename source files to item names
-- @author JG
-- @version 1.0.0
-- @about
--   Renames the underlying source media files on your hard drive to match their current item names in REAPER.
--   Requires the SWS Extension.

-- Check if SWS Extension is installed
if not reaper.BR_SetTakeSourceFromFile then
  reaper.ShowMessageBox("This script requires the SWS Extension!", "Error", 0)
  return
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local item_count = reaper.CountSelectedMediaItems(0)
if item_count == 0 then
  reaper.ShowMessageBox("Please select items!", "Error", 0)
  return
end

local renamed = 0
local errors = {}

-- Set all items offline first
reaper.Main_OnCommand(40440, 0) -- Set selected media offline

for i = 0, item_count - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  local take = reaper.GetActiveTake(item)
  
  if take and not reaper.TakeIsMIDI(take) then
    -- Get item name
    local _, item_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    
    -- Source file info
    local source = reaper.GetMediaItemTake_Source(take)
    local old_path = reaper.GetMediaSourceFileName(source, "")
    
    if old_path ~= "" and item_name ~= "" then
      -- Extract path and file extension
      local dir = old_path:match("^(.*[\\/])") or ""
      local ext = old_path:match("(%.[^%.]+)$") or ".wav"
      
      -- New path
      local new_path = dir .. item_name .. ext
      
      -- Check if target file already exists
      local file_exists = io.open(new_path, "r")
      if file_exists then
        file_exists:close()
        table.insert(errors, item_name .. ": File already exists!")
      else
        -- Rename file
        local success, err = os.rename(old_path, new_path)
        
        if success then
          -- Update REAPER reference
          reaper.BR_SetTakeSourceFromFile(take, new_path, false)
          renamed = renamed + 1
        else
          table.insert(errors, item_name .. ": " .. (err or "Could not rename file"))
        end
      end
    end
  end
end

-- Set all back online
reaper.Main_OnCommand(40439, 0) -- Set selected media online

-- Rebuild peaks
if renamed > 0 then
  reaper.Main_OnCommand(40441, 0)
end

reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("Rename Source Files to Item Names", -1)
reaper.UpdateArrange()

-- Show result
local msg = string.format("Successfully renamed: %d\nErrors: %d", renamed, #errors)
if #errors > 0 then
  msg = msg .. "\n\nErrors:\n" .. table.concat(errors, "\n")
end
reaper.ShowMessageBox(msg, "Done", 0)