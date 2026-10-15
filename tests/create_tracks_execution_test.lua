-- Run the complete script with a minimal REAPER host, including deferred UI confirmation.
local path = 'Tools/JG_Create_Tracks_From_Clipboard.lua'
local function run(text, virtual, stereo)
  local tracks, queue, master = {}, {}, { chunk = '<TRACK\nHWOUT 0 0 1 0 0 0 ""\n>\n' }
  local summary, undo_count = nil, 0
  local noop = function() end
  local api = {
    CF_GetClipboard = function() return text end,
    GetUserInputs = function() return true, '1,' .. (virtual and 'y' or 'n') end,
    ShowMessageBox = function(message) summary = message end,
    defer = function(fn) queue[#queue + 1] = fn end,
    ImGui_CreateContext = function() return {} end,
    ImGui_Cond_Once = function() return 0 end,
    ImGui_Begin = function() return true, true end,
    ImGui_Checkbox = function(_, _, checked) return false, checked end,
    ImGui_Button = function(_, label) return label == 'Create Tracks' end,
    Undo_BeginBlock = function() undo_count = undo_count + 1 end,
    Undo_EndBlock = noop, UpdateArrange = noop,
    CountTracks = function() return #tracks end,
    InsertTrackAtIndex = function() tracks[#tracks + 1] = { chunk = '<TRACK\n>\n' } end,
    GetTrack = function(_, index) return tracks[index + 1] end,
    GetSetMediaTrackInfo_String = function(track, key, value) track[key] = value end,
    SetMediaTrackInfo_Value = function(track, key, value) track[key] = value end,
    GetMasterTrack = function() return master end,
    GetTrackNumSends = function() return 0 end,
    RemoveTrackSend = noop,
    GetTrackStateChunk = function(track) return true, track.chunk end,
    SetTrackStateChunk = function(track, chunk) track.chunk = chunk end,
  }
  for _, name in ipairs({'SetNextWindowSize', 'Text', 'Separator', 'Spacing', 'SameLine', 'End'}) do
    api['ImGui_' .. name] = noop
  end
  local env = setmetatable({ reaper = api }, { __index = _G })
  assert(loadfile(path, 't', env))()
  while #queue > 0 do table.remove(queue, 1)() end
  assert(undo_count == 1, 'Tracks must be created exactly once')
  assert(summary and summary:match('Done!'), 'Creation must finish')
  assert(#tracks == (stereo and 1 or 2), 'Unexpected track count')
  assert(tracks[1].P_NAME == (stereo and 'Git 1' or 'Kick'))
  assert(tracks[1].I_RECINPUT == (stereo and 1024 or 0))
  if virtual then
    assert(not master.chunk:find('HWOUT'), 'Master hardware output must be cleared')
    assert(tracks[1].B_MAINSEND == 0)
    assert(tracks[1].chunk:find(stereo and 'HWOUT 0 0 ' or 'HWOUT 1024 1024 ', 1, true))
  else
    assert(master.chunk:find('HWOUT'), 'Normal mode must preserve master output')
    assert(not tracks[1].chunk:find('HWOUT'))
  end
end
for _, virtual in ipairs({true, false}) do
  run('Kick\nSnare', virtual, false)
  run('Git 1L\nGit 1R', virtual, true)
end
print('Full script execution passed with/without stereo pairs and Virtual Soundcheck')
