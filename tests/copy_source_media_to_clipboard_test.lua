-- Run with: lua tests/copy_source_media_to_clipboard_test.lua
local script = 'Tools/JG_Copy_Source_Media_To_Clipboard.lua'
local function run(items, options)
  options = options or {}
  local messages, calls, helper = {}, 0
  local tmp = os.tmpname()
  local queue, clock, exit_callback = {}, 0
  local pending_result
  local tooltip
  local api = {
    defer = function(fn) queue[#queue + 1] = fn end,
    atexit = function(fn) exit_callback = fn end,
    time_precise = function() return clock end,
    GetMousePosition = function() return 0, 0 end,
    TrackCtl_SetToolTip = function(text) if text ~= '' then tooltip = text end end,
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
    ExecProcess = function(command, timeout)
      assert(timeout == -2, "Clipboard helper must never block REAPER")
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
      pending_result = options.failure and 'JG_COPY_ERROR: Clipboard busy' or 'JG_COPY_OK'
      for _, item in ipairs(items) do
        if item.source and item.source.path == '/missing.wav' then
          pending_result = 'JG_COPY_ERROR: Source file is no longer available: /missing.wav'
        end
      end
      return '-3' -- Launch return codes are not completion status.
    end,
  }
  local fake_os = setmetatable({tmpname = function() return tmp end}, {__index = os})
  assert(loadfile(script, 't', setmetatable({reaper = api, os = fake_os}, {__index = _G})))()
  assert(#messages == 0 or calls == 0, 'Must wait for asynchronous completion')
  local ticks = 0
  while #queue > 0 do
    ticks = ticks + 1; assert(ticks < 1000, 'Polling did not finish')
    clock = clock + 0.1
    if ticks == 5 and pending_result and not options.timeout then
      local result = assert(io.open(tmp .. '.result', 'wb'))
      result:write(pending_result); result:close()
    end
    table.remove(queue, 1)()
  end
  if exit_callback then exit_callback() end
  assert(not io.open(tmp .. '.result', 'rb'), 'Result file was not removed')
  local f = io.open(tmp, 'rb')
  -- Early exits do not use the reserved test filename.
  if calls > 0 then assert(not f, 'Temporary helper was not removed') end
  if f then f:close(); os.remove(tmp) end
  return messages, calls, helper, tooltip
end
local source = {path = '/tmp/Äudio \' " $` test.wav'}
local messages, calls, helper = run({{source = source}, {source = {parent = source}}, {}}, {export = arg[1]})
assert(calls == 1 and messages[1]:find('Copied 1 source file', 1, true))
assert(messages[1]:find('Skipped 1 item', 1, true))
assert(not helper:find(source.path, 1, true), 'Paths must be encoded as data')
messages, calls = run({{source = {path = '/missing.wav'}}, {source = source}})
assert(calls == 1 and messages[1]:find('Source file is no longer available', 1, true))
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
messages, calls = run({{source = source}}, {timeout = true})
assert(calls == 1 and messages[1]:find('20 seconds', 1, true))
local tip
messages, calls, helper, tip = run({
  {source = {path = '/tmp/one.wav'}},
  {source = {path = '/tmp/two.wav'}},
  {source = {path = '/tmp/three.wav'}},
  {source = {path = '/tmp/two.wav'}},
})
assert(calls == 1 and #messages == 0)
assert(tip == 'Copied 3 unique source file(s) from 4 selected item(s).')
local entries = assert(helper:match('var entries = %[(.-)%];'))
local n = 0
for _ in entries:gmatch("'[^']+'") do n = n + 1 end
assert(n == 3, 'Every distinct selected source must reach the OS helper')
print('copy_source_media_to_clipboard_test: OK')
