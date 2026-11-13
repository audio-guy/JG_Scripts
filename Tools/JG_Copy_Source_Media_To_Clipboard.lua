-- @description Copy source media files to clipboard
-- @author Julius Gass
-- @version 1.0.1
-- @about
--   Copies the source files of selected items' active takes to the system clipboard.
--   Paste in Finder (Cmd+V) or Windows Explorer (Ctrl+V) to copy the files.
--   Copies entire original files, not trimmed items or rendered FX. Removes duplicates.
--   Resolves section/reverse sources to their underlying files. In-project MIDI and
--   empty items are skipped with a notice. Missing files abort without changing the clipboard.
--   Supports macOS and Windows using built-in OS helpers; no REAPER extensions needed.
-- @changelog
--   Run clipboard helpers asynchronously to keep REAPER responsive and avoid false timeout errors.

local TITLE = "Copy source media files to clipboard"
local function message(text) reaper.ShowMessageBox(text, TITLE, 0) end
-- Suppress REAPER's automatic undo point: this action does not edit the project.
reaper.defer(function() end)
local platform = reaper.GetOS()
local windows = platform:match("^Win") ~= nil
if not windows and not platform:match("^OSX") and not platform:match("^macOS") then
  message("This script supports macOS and Windows only.")
  return
end
local count = reaper.CountSelectedMediaItems(0)
if count == 0 then message("Select at least one media item."); return end

local paths, seen, skipped = {}, {}, 0
for i = 0, count - 1 do
  local take = reaper.GetActiveTake(reaper.GetSelectedMediaItem(0, i))
  local source = take and reaper.GetMediaItemTake_Source(take)
  local ancestors = {}
  while source and not ancestors[source] do
    ancestors[source] = true
    local parent = reaper.GetMediaSourceParent(source)
    if not parent then break end
    source = parent
  end
  local path = source and reaper.GetMediaSourceFileName(source, "") or ""
  if path == "" then
    skipped = skipped + 1
  else
    -- REAPER normally returns absolute paths. Resolve relative sources against the project.
    if not path:match("^/") and not path:match("^%a:[/\\]") and not path:match("^\\\\") then
      path = reaper.GetProjectPathEx(0, "") .. (windows and "\\" or "/") .. path
    end
    local key = windows and path:gsub("/", "\\"):lower() or path
    if not seen[key] then
      seen[key] = true
      paths[#paths + 1] = path
    end
  end
end
if #paths == 0 then message("No source files found. Empty items and in-project MIDI have no file to copy."); return end

local function base64(value)
  local alphabet, result = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", {}
  for i = 1, #value, 3 do
    local a, b, c = value:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    result[#result + 1] = alphabet:sub((n >> 18) + 1, (n >> 18) + 1)
      .. alphabet:sub(((n >> 12) & 63) + 1, ((n >> 12) & 63) + 1)
      .. (b and alphabet:sub(((n >> 6) & 63) + 1, ((n >> 6) & 63) + 1) or "=")
      .. (c and alphabet:sub((n & 63) + 1, (n & 63) + 1) or "=")
  end
  return table.concat(result)
end
local encoded = {}
for _, path in ipairs(paths) do encoded[#encoded + 1] = "'" .. base64(path) .. "'" end
-- Only base64 data is interpolated into helper code; filenames cannot become commands.
local helper
if windows then
  helper = [=[
$ErrorActionPreference = 'Stop'
try {
  Add-Type -AssemblyName System.Windows.Forms
  $files = New-Object System.Collections.Specialized.StringCollection
  foreach ($entry in @(]=] .. table.concat(encoded, ",") .. [=[)) {
    $path = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry))
    if (-not [IO.File]::Exists($path)) { throw "Source file is no longer available: $path" }
    [void]$files.Add($path)
  }
  $data = New-Object System.Windows.Forms.DataObject
  $data.SetFileDropList($files)
  $effect = New-Object System.IO.MemoryStream
  $effect.Write([byte[]](1,0,0,0), 0, 4)
  $effect.Position = 0
  $data.SetData('Preferred DropEffect', $effect)
  [Windows.Forms.Clipboard]::SetDataObject($data, $true, 10, 100)
  'JG_COPY_OK'
} catch {
  'JG_COPY_ERROR: ' + $_.Exception.Message
}
]=]
else
  helper = [=[
ObjC.import('AppKit');
var entries = [
]=] .. table.concat(encoded, ",") .. [=[
];
var urls = $.NSMutableArray.alloc.init;
entries.forEach(function(entry) {
  var data = $.NSData.alloc.initWithBase64EncodedStringOptions($(entry), 0);
  var path = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
  if (!$.NSFileManager.defaultManager.fileExistsAtPath(path))
    throw new Error('Source file is no longer available: ' + ObjC.unwrap(path));
  urls.addObject($.NSURL.fileURLWithPath(path));
});
var board = $.NSPasteboard.generalPasteboard;
if (board.isNil()) throw new Error('The macOS clipboard service is unavailable.');
board.clearContents;
if (!board.writeObjects(urls)) throw new Error('Could not write files to the clipboard.');
return 'JG_COPY_OK';
]=]
end

local ok, temporary = pcall(os.tmpname)
if not ok or not temporary then message("Could not create a temporary clipboard helper."); return end
local result_path = temporary .. ".result"
local function cleanup()
  os.remove(temporary)
  os.remove(result_path)
end
reaper.atexit(cleanup)
if windows then
  local decode = "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s'))"
  helper = "& {\n" .. helper .. "\n} | ForEach-Object { [IO.File]::WriteAllText("
    .. string.format(decode, base64(result_path)) .. ", [string]$_) }"
  helper = helper:gsub("  %$data = New%-Object", "  if (-not [IO.File]::Exists("
    .. string.format(decode, base64(temporary)) .. ")) { return }\n  $data = New-Object", 1)
else
  local function js_path(path)
    return "$.NSString.alloc.initWithDataEncoding($.NSData.alloc.initWithBase64EncodedStringOptions($('"
      .. base64(path) .. "'), 0), $.NSUTF8StringEncoding)"
  end
  helper = helper:gsub("var board =", "if (!$.NSFileManager.defaultManager.fileExistsAtPath("
    .. js_path(temporary) .. ")) return '';\nvar board =", 1)
  helper = "ObjC.import('Foundation');\nfunction copyFiles() {\n" .. helper .. [[
}
var result;
try { result = copyFiles(); }
catch (error) { result = 'JG_COPY_ERROR: ' + String(error); }
]] .. "if ($.NSFileManager.defaultManager.fileExistsAtPath(" .. js_path(temporary) .. ")) {\n"
    .. "$(result).writeToFileAtomicallyEncodingError(" .. js_path(result_path)
    .. ", true, $.NSUTF8StringEncoding, null);\n}\n"
end
local file, err = io.open(temporary, "wb")
if not file then os.remove(temporary); message("Could not write clipboard helper:\n" .. tostring(err)); return end
local written, write_error = file:write(helper)
local closed, close_error = file:close()
if not written or not closed then
  os.remove(temporary)
  message("Could not write clipboard helper:\n" .. tostring(write_error or close_error))
  return
end
local command
if windows then
  -- The ASCII launcher is encoded as UTF-16LE for PowerShell. No shell path quoting needed.
  local launcher = "$ErrorActionPreference='Stop'; try { & ([scriptblock]::Create([IO.File]::ReadAllText([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"
    .. base64(temporary) .. "'))))) } catch { Write-Output $_.Exception.Message; exit 1 }"
  command = 'powershell.exe -NoLogo -NoProfile -NonInteractive -STA -EncodedCommand '
    .. base64((launcher:gsub('.', function(c) return c .. '\0' end)))
else
  command = '/usr/bin/osascript -l JavaScript "' .. temporary:gsub('([\\"$`])', '\\%1') .. '"'
end
-- Never wait for the OS helper on REAPER's UI thread. In particular, osascript
-- can publish the clipboard successfully before its process exits.
local executed, output = pcall(reaper.ExecProcess, command, -2)
if not executed then
  cleanup()
  message("Could not start the clipboard helper.\n\n" .. tostring(output))
  return
end
local deadline = reaper.time_precise() + 20
local next_poll = 0
local function poll()
  local now = reaper.time_precise()
  if now >= next_poll then
    next_poll = now + 0.1
    local result_file = io.open(result_path, "rb")
    local result
    if result_file then result = result_file:read("*a"); result_file:close() end
    if result and result ~= "" then
      cleanup()
      if result ~= "JG_COPY_OK" then
        message("Could not copy source files to the clipboard.\n\n" .. result)
      elseif skipped > 0 then
        message(string.format("Copied %d source file(s).\nSkipped %d item(s) without a source file (empty items or in-project MIDI).", #paths, skipped))
      else
        local x, y = reaper.GetMousePosition()
        reaper.TrackCtl_SetToolTip(string.format("Copied %d unique source file(s) from %d selected item(s).", #paths, count), x + 16, y + 16, true)
        local hide_at = reaper.time_precise() + 3
        local function hide_tooltip()
          if reaper.time_precise() < hide_at then reaper.defer(hide_tooltip)
          else reaper.TrackCtl_SetToolTip("", 0, 0, true) end
        end
        reaper.defer(hide_tooltip)
      end
      return
    end
  end
  if now >= deadline then
    cleanup()
    message("The clipboard helper did not respond within 20 seconds. Please try again.")
    return
  end
  reaper.defer(poll)
end
reaper.defer(poll)
