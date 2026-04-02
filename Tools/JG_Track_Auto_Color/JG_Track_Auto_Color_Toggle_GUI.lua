-- @description Track Auto Color - Toggle GUI
-- @author JG
-- @version 1.0.0
-- @about
--   Toggles the GUI of JG Track Auto Color (which runs in the background).
--   Bind this to a keyboard shortcut or toolbar button for quick access.

local EXT_SECTION = "JG_TrackAutoColor"

if reaper.GetExtState(EXT_SECTION, "running") ~= "1" then
  reaper.MB("Track Auto Color is not running.\nStart it first via Actions or SWS Startup Action.", "Track Auto Color", 0)
  return
end

local vis = reaper.GetExtState(EXT_SECTION, "gui_visible")
reaper.SetExtState(EXT_SECTION, "gui_visible", vis == "1" and "0" or "1", false)
