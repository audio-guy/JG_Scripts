-- Run with: lua tests/copy_source_media_to_clipboard_test.lua
local script = 'Tools/JG_Copy_Source_Media_To_Clipboard.lua'
local function run(items, options)
  options = options or {}
  local messages, calls, helper = {}, 0
  local tmp = os.tmpname()
  local api = {
    defer = function() end,
    GetOS = function() return options.os or 'OSX64' end,
    CountSelectedMediaItems = function() return #items end,
    GetSelectedMediaItem = function(_, i) return items[i + 1] end,
    GetActiveTake = function(item) return item.source and item end,
    GetMediaItemTake_Source = function(take) return take.source end,
    GetMediaSourceParent = function(source) return source.parent end,
    GetMediaSourceFileName = function(source) return source.path or '' end,
    GetProjectPathEx = function() return '/project' end,
    file_exists = function(path) return path ~= '/missing.wav' end,
    ShowMessageBox = function(msg) messages[#messages + 1] = msg end,
    ExecProcess = function(command)
      calls = calls + 1
      local f = assert(io.open(tmp, 'rb')); helper = f:read('*a'); f:close()
      if options.os == 'Win64' then
        assert(command:match('^powershell.exe .*%-STA %-EncodedCommand [A-Za-z0-9+/=]+$'))
        assert(helper:find("Preferred DropEffect", 1, true))
        assert(helper:find('SetDataObject($data, $true, 10, 100)', 1, true))
      else assert(command:find('/usr/bin/osascript', 1, true)) end
      if options.export then
        local out = assert(io.open(options.export, 'wb')); out:write(helper); out:close()
      end
      return options.failure and '1\nClipboard busy' or '0\nJG_COPY_OK\n'
    end,
  }
  local fake_os = setmetatable({tmpname = function() return tmp end}, {__index = os})
  assert(loadfile(script, 't', setmetatable({reaper = api, os = fake_os}, {__index = _G})))()
  local f = io.open(tmp, 'rb')
  -- Early exits do not use the reserved test filename.
  if calls > 0 then assert(not f, 'Temporary helper was not removed') end
  if f then f:close(); os.remove(tmp) end
  return messages, calls, helper
end
local source = {path = '/tmp/Äudio \' " $` test.wav'}
local messages, calls, helper = run({{source = source}, {source = {parent = source}}, {}}, {export = arg[1]})
assert(calls == 1 and messages[1]:find('Copied 1 source file', 1, true))
assert(messages[1]:find('Skipped 1 item', 1, true))
assert(not helper:find(source.path, 1, true), 'Paths must be encoded as data')
messages, calls = run({{source = {path = '/missing.wav'}}, {source = source}})
assert(calls == 0 and messages[1]:find('clipboard was not changed', 1, true))
messages, calls = run({{}, {source = {}}})
assert(calls == 0 and messages[1]:find('No source files', 1, true))
messages, calls = run({})
assert(calls == 0 and messages[1]:find('Select at least', 1, true))
messages, calls = run({{source = source}}, {failure = true})
assert(calls == 1 and messages[1]:find('Clipboard busy', 1, true))
messages, calls = run({{source = {path = 'C:\\Audio\\Test.wav'}}, {source = {path = 'c:/audio/test.wav'}}}, {os = 'Win64'})
assert(calls == 1 and #messages == 0)
messages, calls = run({{source = source}}, {os = 'Linux'})
assert(calls == 0 and messages[1]:find('macOS and Windows only', 1, true))
print('copy_source_media_to_clipboard_test: OK')
