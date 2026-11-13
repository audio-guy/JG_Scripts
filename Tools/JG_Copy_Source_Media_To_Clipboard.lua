-- @description Copy source media files to clipboard
-- @author Julius Gass
-- @version 1.0.0
-- @about
--   Copies the source files of selected items' active takes to the system clipboard.
--   Paste in Finder (Cmd+V) or Windows Explorer (Ctrl+V) to copy the files.
--   Copies entire original files, not trimmed items or rendered FX. Removes duplicates.
--   Resolves section/reverse sources to their underlying files. In-project MIDI and
--   empty items are skipped with a notice. Missing files abort without changing the clipboard.
--   Supports macOS and Windows using built-in OS helpers; no REAPER extensions needed.
-- @changelog
--   Initial release.

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

local paths, seen, missing, skipped = {}, {}, {}, 0
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
      if reaper.file_exists(path) then paths[#paths + 1] = path
      else missing[#missing + 1] = path end
    end
  end
end
if #missing > 0 then
  message("The clipboard was not changed. Source files are missing or unreadable:\n\n" .. table.concat(missing, "\n"))
  return
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
  Write-Output 'JG_COPY_OK'
} catch {
  Write-Output $_.Exception.Message
  exit 1
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
'JG_COPY_OK';
]=]
end

local ok, temporary = pcall(os.tmpname)
if not ok or not temporary then message("Could not create a temporary clipboard helper."); return end
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
local executed, output = pcall(reaper.ExecProcess, command, 15000)
os.remove(temporary)
if not executed or not output or not output:match("^0[\r\n]") or not output:find("JG_COPY_OK", 1, true) then
  message("Could not copy source files to the clipboard.\n\n" .. tostring(output or "The OS helper did not return a result."))
  return
end
if skipped > 0 then
  message(string.format("Copied %d source file(s).\nSkipped %d item(s) without a source file (empty items or in-project MIDI).", #paths, skipped))
end
