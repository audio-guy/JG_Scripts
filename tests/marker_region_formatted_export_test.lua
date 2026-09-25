-- Run from the repository root: lua tests/marker_region_formatted_export_test.lua
local path = 'Tools/JG_Marker_Region_Formatted_Export.lua'
local f = assert(io.open(path)); local source = f:read('*a'); f:close()
source = assert(source:match('^(.-)\n%-%- Entry'))
local ext, projExt, clipboard = {}, {}, ''
local items = {
  {false, 0, 0, '#Intro', 1, 0},
  {false, 10, 0, '#Hidden', 2, 0},
  {true, 20, 25, 'Take.wav', 3, 0},
  {false, 30, 0, 'Outro', 4, 0},
}
reaper = {
  ImGui_CreateContext = function() return {} end,
  ImGui_CreateFont = function() return {} end,
  ImGui_Attach = function() end,
  GetExtState = function(_, k) return ext[k] or '' end,
  SetExtState = function(_, k, v) ext[k] = v end,
  GetProjExtState = function(_, _, k) return 1, projExt[k] or '' end,
  SetProjExtState = function(_, _, k, v) projExt[k] = v end,
  CountProjectMarkers = function() return 4, 3, 1 end,
  EnumProjectMarkers3 = function(_, i) return 1, table.unpack(items[i+1]) end,
  EnumProjects = function() return 'project', '' end,
  GetProjectStateChangeCount = function() return 1 end,
  CountTracks = function() return 0 end,
  format_timestr_pos = function(t, _, mode)
    if mode == -1 then return '01:00:00:12' end
    assert(mode == 2); return '12.3.50'
  end,
  CF_SetClipboard = function(s) clipboard = s end,
}
local api = assert(load(source .. [[
return {prefs=prefs, proj=proj, patterns=namePatterns, include=includeName,
loadPrefs=loadPrefs, savePrefs=savePrefs, loadProj=loadProj, saveProj=saveProj,
fmtPos=fmtPos, rows=buildRowsAndStats, pages=buildPages, pdf=buildPdf, text=exportText}
]], path))()
local function matches(name, inc, exc)
  return api.include(name, api.patterns(inc or ''), api.patterns(exc or ''))
end
assert(matches('#Song', '#*'))
assert(not matches('Song#', '#*'))
assert(matches('Take.wav', '*.wav'))
assert(not matches('TakeXwav', '*.wav'))
assert(not matches('Take.wav.bak', '*.wav'))
for _, name in ipairs({'Intro', 'Intro Song', 'Song Intro', 'Song Intro End'}) do
  assert(matches(name, '*Intro*'))
end
assert(not matches('Intro Song', '* Intro *'))
assert(matches('Song Intro End', '* Intro *'))
assert(not matches('intro', '*Intro*'))
assert(matches('a.[x]+%?()-^$', 'a.[x]+%?()-^$'))
assert(matches('Take.wav', ' #* ; *.wav ; '))
assert(not matches('#Intro.wav', '#*', '*.wav'))
assert(matches('', ' ; '))
assert(not matches('', '', '*'))
ext.timeMode = 'bar'; api.loadPrefs(); assert(api.prefs.timeMode == 'timeline')
assert(api.fmtPos(1) == '01:00:00:12')
api.prefs.timeMode = 'bar'; assert(api.fmtPos(1) == '12.3')
api.prefs.timeMode = 'time'; assert(api.fmtPos(61) == '1:01')
api.prefs.timeMode = 'timeline'; api.savePrefs()
api.prefs.timeMode = 'bar'; api.loadPrefs(); assert(api.prefs.timeMode == 'timeline')
api.prefs.prefix = '#'; api.prefs.blacklist = ''
api.proj.includeNames = '#*'; api.proj.excludeNames = '#Hidden'
api.saveProj(); api.proj.includeNames = ''; api.loadProj()
assert(api.proj.includeNames == '#*')
local rows, stats = api.rows()
assert(#rows == 1 and rows[1].name == 'Intro' and rows[1].len == '0:10')
assert(stats.shown == 1 and stats.total == 4 and stats.netMusic == 10)
api.proj.includeNames = '*.wav'; api.proj.excludeNames = ''
rows = api.rows(); assert(#rows == 1 and rows[1].name == 'Take.wav' and rows[1].len == '0:05')
api.proj.laneInclude['r:0'] = false; assert(#api.rows() == 0)
api.proj.laneInclude = {}; api.proj.includeNames = ''
rows = api.rows()
local meta = {title='Formatted Export Test', subtitle='Synthetic marker data'}
local xWithLength
for _, show in ipairs({true, false}) do
  api.prefs.showLength = show
  api.savePrefs(); api.prefs.showLength = not show; api.loadPrefs()
  assert(api.prefs.showLength == show)
  local pages = api.pages(rows, meta)
  local start, position, length, nameX = false, false, false
  for _, op in ipairs(pages[1]) do
    start = start or op.text == 'Start'; position = position or op.text == 'Position'
    length = length or op.text == 'Länge'
    if op.text == 'Name' then nameX = op.x end
  end
  assert(start == show and position == not show and length == show)
  if show then xWithLength = nameX else assert(nameX < xWithLength) end
  api.text()
  local first = clipboard:match('([^\n]+)')
  local _, tabs = first:gsub('\t', '')
  assert(tabs == (show and 3 or 2))
  if arg[1] then
    local out = assert(io.open(arg[1] .. (show and '-length.pdf' or '-position.pdf'), 'wb'))
    out:write(api.pdf(pages)); out:close()
  end
end
print('Marker/region export: filter, persistence, time, duration, layout and text checks passed')
