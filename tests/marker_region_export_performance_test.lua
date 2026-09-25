-- Real GUI update path with synthetic large project data; no REAPER required.
-- Run: lua tests/marker_region_export_performance_test.lua
local f=assert(io.open('Tools/JG_Marker_Region_Formatted_Export.lua'))
local source=f:read('*a'); f:close()
source=assert(source:match('^(.-)\n%-%- Entry'))
local line='      POSITION 123.456 LENGTH 1.0 VOLPAN 1 0 1 -1\n'
local chunk=string.rep(line,math.floor(20*1024*1024/#line))
local records = {}
for lane=1,4 do records[#records+1]='RULERLANE '..lane..' 0 Lane'..lane..' 0 1 0' end
for i=0,103 do
  records[#records+1]=string.format('MARKER %d %d "Entry %d" %d 0 1 B {12345678-0000-0000-0000-%012d} 0 %d', i,i*10,i,i<29 and 1 or 0,i,i%4+1)
end
chunk=table.concat(records, '\n')..'\n'..chunk
local reads,enums,tracks=0,0,0
local timeline=''
local clicked
local rename='Entry '
local lastSavedProject
local revision,active,path=1,'project-A',''
local ext={}
reaper=setmetatable({
 GetProjectStateChunk=function() reads=reads+1; return true,chunk end,
 EnumProjects=function() return active,path end,
 GetProjectStateChangeCount=function() return revision end,
 GetExtState=function() return '' end,
 SetExtState=function() end,
 GetProjExtState=function(project,_,key) return 1,ext[project..key] or '' end,
 SetProjExtState=function(project,_,key,value) lastSavedProject=project; ext[project..key]=value; revision=revision+1 end,
 CountProjectMarkers=function() enums=enums+1; return 104,75,29 end,
 EnumProjectMarkers3=function(_,i) return 1,i<29,i*10,i*10+5,rename..i,i,0 end,
 CountTracks=function() tracks=tracks+1; return 0 end,
 format_timestr_pos=function(t) return timeline..tostring(t) end,
 ImGui_Button=function(_,label)
   if clicked==label then clicked=nil; return true end
   return false
 end,
}, {__index=function(_,key)
 if key:match('Flags_') then return function() return 0 end end
 if key:match('^ImGui_') then return function() return false end end
end})
local api=assert(load(source..'\nreturn {draw=drawGUI, prefs=prefs, proj=proj, loop=loop, rows=buildRowsAndStats, snapshot=projectSnapshot, save=saveProj, toggle=togglePreviewOverride}', 'export'))()
api.draw()
local initialReads,initialEnums,initialTracks=reads,enums,tracks
local start=os.clock()
for i=1,5 do api.draw() end
local elapsed=os.clock()-start
print(string.format('20 MB / 104 entries: %.3f ms per unchanged update; %d reads / %d enumerations after warm-up', elapsed*1000/5,reads-initialReads,enums-initialEnums))
assert(reads==initialReads,'Unchanged GUI updates must not scan project data')
assert(enums==initialEnums,'Unchanged GUI updates must not enumerate markers')
assert(tracks==initialTracks,'Unchanged GUI updates must not scan tracks')
assert(initialReads==1 and initialEnums==1,'Lanes and preview must share one snapshot')
api.proj.includeNames='Entry 1*'; api.draw()
assert(reads==initialReads and enums==initialEnums,'Name filters must reuse project snapshot')
revision=revision+1; api.draw()
assert(reads==initialReads+1 and enums==initialEnums+1,'Project edits must refresh snapshot once')
local snapshot=api.snapshot()
assert(#snapshot.lanes==4 and snapshot.byLane, 'Four named lanes must survive caching')
local rows=api.rows()
assert(rows[1].guid and rows[1].name=='Entry 1')
api.proj.includeNames=''; rows=api.rows()
assert(#rows==104 and rows[1].isSong and rows[1].len=='0:05')
api.prefs.regionAsSong=false
assert(not api.rows()[1].isSong)
api.prefs.regionAsSong=true
rows=api.rows(); api.toggle(rows[1])
assert(not api.rows()[1].isSong, 'Override must invalidate derived rows')
local before=reads
api.save(); api.draw()
assert(reads==before, 'Saving export options must not re-read project data')
local unchanged=api.rows(); api.draw()
assert(api.rows()==unchanged, 'Idle preview must reuse derived rows')
timeline='TC:'; api.draw()
assert(api.rows()[1].start=='TC:0' and reads==before, 'Ruler format changes must refresh timestamps only')
rename='Renamed '; revision=revision+1; api.draw()
assert(api.rows()[1].name=='Renamed 0' and reads==before+1)
clicked='Refresh'; api.draw(); api.draw()
assert(reads==before+2, 'Explicit Refresh must reload once')
path='saved-as.rpp'; api.draw()
assert(reads==before+3, 'Save As must invalidate snapshot')
-- A pending override belongs to the original tab, even after the user switches.
api.toggle(api.rows()[1]); active='project-B'
ext['project-BincludeNames']='Renamed 2*'
api.draw()
assert(lastSavedProject=='project-A', 'Never write the old tab settings into the new tab')
assert(api.proj.includeNames=='Renamed 2*' and #api.rows()==11)
active='project-A'; api.draw()
assert(api.proj.includeNames=='' and #api.rows()==104)
-- Exercise the saved-file fallback separately, including CRLF line endings.
local fixture=os.tmpname()
local out=assert(io.open(fixture,'wb'))
out:write(table.concat(records,'\r\n')..'\r\n<TRACK\r\n  NAME "Ignore LANE in track content"\r\n>\r\n')
out:close()
reaper.GetProjectStateChunk=nil
path=fixture; api.draw()
assert(#api.snapshot().lanes==4 and api.rows()[1].guid, 'Saved-file lane parsing must remain intact')
os.remove(fixture)
print('Performance and cache invalidation checks passed')
