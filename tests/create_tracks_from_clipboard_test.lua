-- Exercise the script's parsing and stereo detection without REAPER's UI.
local file = assert(io.open('Tools/JG_Create_Tracks_From_Clipboard.lua', 'r'))
local source = file:read('*a')
file:close()
local detection = assert(source:match('^(.-)%-%- ─── Step 4:'))
local function detect(text)
  local env = setmetatable({ reaper = {
    CF_GetClipboard = function() return text end,
    ImGui_CreateContext = function() end,
    GetUserInputs = function() return true, '1,n' end,
    ShowMessageBox = function(message) error(message) end,
  } }, { __index = _G })
  return assert(load(detection .. '\nreturn pairs_found', 'stereo detection', 't', env))()
end
local function expect_pair(text, name)
  local pairs = detect(text)
  for _, pair in ipairs(pairs) do
    if pair.base_name == name then return end
  end
  error('Missing stereo pair: ' .. name)
end
expect_pair('Git 1L\nGit 1R', 'Git 1')
expect_pair('Git 1l\nGit 1r', 'Git 1')
expect_pair('Guitar 12L\nGuitar 12R', 'Guitar 12')
local full = 'Kick\nSnare\nOH L\nOH R\nVoc 1\nVoc 2\nBass\nKey L\nKey R\nGit 1L\nGit 1R\nPno'
for _, name in ipairs({ 'OH', 'Voc', 'Key', 'Git 1' }) do expect_pair(full, name) end
expect_pair('OH_L\nOH_R', 'OH')
assert(#detect('Git 1L\nGit 2R') == 0, 'Different numbered instruments must stay separate')
expect_pair('GuitarL\nGuitarR', 'Guitar')
expect_pair('Synthl\nSynthR', 'Synth')
expect_pair('Guitar-L\nGuitar-R', 'Guitar-')
assert(#detect('GuitarL\nBass\nGuitarR') == 0, 'Only adjacent names should pair')
assert(#detect('L\nR') == 0, 'A shared name is required')
print('Clipboard stereo detection tests passed')
