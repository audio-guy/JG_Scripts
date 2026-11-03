-- Exercise the actual REAPER adapter and UI loop with a deterministic mock host.
local M=assert(loadfile('Tools/JG_Recording_Scheduler.lua'))('__test')
local C,H,E=M.Core,M.Host,M.Engine
local root=os.tmpname(); os.remove(root); assert(os.execute('mkdir -p '..string.format('%q',root)))
local files,dirs={},{}
local function write(path,contents) local f=assert(io.open(path,'wb')); assert(f:write(contents)); f:close(); files[path]=true end
local tests=0
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function test(name,fn) local ok,err=pcall(fn); if not ok then error(name..': '..tostring(err)) end; tests=tests+1; print('PASS '..name) end
local function rig()
  local p,other,track={},{},{}; local selected=p; local rec=false; local sources={}
  local cfg={RECORD_PATH='original',RECTAG='original tag'}; local commands={}; local stopped=0
  local api={
    EnumProjects=function(i) if i==-1 then return selected,root..'/session.rpp' elseif i==0 then return p,root..'/session.rpp' elseif i==1 then return other,root..'/other.rpp' end end,
    ValidatePtr=function(obj) return obj==p end, ValidatePtr2=function(project,t) eq(project,p); return t==track end,
    GetPlayStateEx=function(project) eq(project,p); return rec and 5 or 0 end,
    CountTracks=function(project) eq(project,p); return 1 end, GetTrack=function(project) eq(project,p); return track end,
    GetMediaTrackInfo_Value=function(_,key) return key=='I_RECARM' and 1 or 0 end,
    GetAudioDeviceInfo=function() return true,'48000' end, GetSetRepeatEx=function(project) eq(project,p); return 0 end,
    GetProjectPathEx=function(project) eq(project,p); return root end,
    GetProjectTimeOffset=function() return 0 end,
    GetMediaItemInfo_Value=function(_,key) return key=='D_POSITION' and 0 or 60 end,
    RecursiveCreateDirectory=function(path) dirs[path]=true; assert(os.execute('mkdir -p '..string.format('%q',path))) end,
    genGuid=function() return '{probe}' end,
    GetSetProjectInfo_String=function(project,key,value,set) eq(project,p); if set then cfg[key]=value end; return true,cfg[key] end,
    CountTrackMediaItems=function() return #sources end, GetTrackMediaItem=function(_,i) return sources[i+1] end,
    CountTakes=function() return 1 end, GetTake=function(item) return item end, TakeIsMIDI=function() return false end,
    GetMediaItemTake_Source=function(take) return take end, GetMediaSourceFileName=function(source) return source end, GetMediaSourceLength=function() return 60,false end,
    GetCursorPositionEx=function(project) eq(project,p); return 5 end, GetProjectLength=function(project) eq(project,p); return 100 end,
    SetEditCurPos2=function(project,position) eq(project,p); eq(position,70200) end,
    Main_OnCommandEx=function(cmd,_,project) eq(project,p); eq(cmd,1013); rec=true; commands[#commands+1]=cmd end,
    OnStopButtonEx=function(project) eq(project,p); rec=false; stopped=stopped+1 end,
    AddProjectMarker2=function(project) eq(project,p) end, GetPlayPositionEx=function(project) eq(project,p); return 100 end,
  }
  local h=H.new(api,p)
  return h,api,cfg,sources,commands,function() selected=other end,function() return stopped end
end
local function slot(name)
  return assert(C.make{name=name or 'Konzert',date='261102',start='19:30',enddate='261102',finish='20:30',pre='0',post='0'})
end

test('0052 recording uses timeline 00:52 rather than cursor or project end',function()
  local h,api=rig(); local position
  api.GetCursorPositionEx=function() return 269 end
  api.GetProjectLength=function() return 269 end
  api.GetProjectTimeOffset=function() return 0 end
  api.SetEditCurPos2=function(_,value) position=value end
  local s=assert(C.make{name='Clock placement',date='261103',start='0052',finish='0053'})
  assert(h:start(s,'')); eq(position,52*60)
end)
test('timeline placement honors project offset and actual late start',function()
  local h,api=rig(); local position
  api.GetProjectTimeOffset=function() return 3600 end
  api.SetEditCurPos2=function(_,value) position=value end
  local s=slot(); assert(h:start(s,'',false,s.start+3,C.midnight(s.start)))
  eq(position,70203-3600)
end)
test('next-day slots keep their chronological timeline position',function()
  local h,api=rig(); local position
  api.SetEditCurPos2=function(_,value) position=value end
  local first=assert(C.datetime('261102','23:00'))
  local s=assert(C.make{name='Next day',date='261103',start='0052',finish='0053'})
  assert(h:start(s,'',false,s.start,C.midnight(first))); eq(position,86400+3120)
end)
test('overlapping media blocks recording before any settings or transport change',function()
  local h,api,cfg,sources,commands=rig(); sources[1]='existing.wav'
  api.GetMediaItemInfo_Value=function(_,key) return key=='D_POSITION' and 70200 or 60 end
  local ok,err=h:start(slot(),''); assert(not ok and err:find('overlaps'))
  eq(#commands,0); eq(cfg.RECORD_PATH,'original'); eq(cfg.RECTAG,'original tag')
  api.GetMediaItemInfo_Value=function(_,key) return key=='D_POSITION' and 80000 or 60 end
  local s=slot(); s.finish=nil; assert(not h:start(s,''))
end)
test('negative position from project start offset fails instead of seeking elsewhere',function()
  local h,api,cfg,sources,commands=rig(); api.GetProjectTimeOffset=function() return 86400 end
  local ok,err=h:start(slot(),''); assert(not ok and err:find('timeline start')); eq(#commands,0)
end)
test('adapter sets dedicated folder and restores exact original settings',function()
  local h,api,cfg=rig(); local s=slot(); assert(h:preflight()); assert(h:start(s,'')); eq(cfg.RECORD_PATH,root..'/261102 - 1930 Konzert'); eq(cfg.RECTAG,'261102 - 1930 Konzert'); eq(s.folder,cfg.RECORD_PATH)
  h:stop(); h:restore(); eq(cfg.RECORD_PATH,'original'); eq(cfg.RECTAG,'original tag')
end)
test('adapter verification requires new nonempty files in slot directory',function()
  local h,api,cfg,sources=rig(); local old=root..'/old.wav'; write(old,'old'); sources[1]=old
  assert(h:start(slot(),'')); assert(not h:verify())
  local unrelated=root..'/unrelated.wav'; write(unrelated,'unrelated'); sources[2]=unrelated; assert(not h:verify())
  local file=cfg.RECORD_PATH..'/input.wav'; write(file,''); sources[3]=file; assert(not h:verify())
  write(file,'new recorded audio'); api.GetMediaSourceLength=function() return 0,false end; assert(not h:verify()); api.GetMediaSourceLength=function() return 60,false end; assert(h:verify()); eq(h.result_files[1],file); h:stop(); h:restore()
end)
test('adapter never restores over deliberate external path change',function()
  local h,api,cfg=rig(); assert(h:start(slot(),'')); cfg.RECORD_PATH='user change'; h:stop(); h:restore(); eq(cfg.RECORD_PATH,'user change')
end)
test('adapter stop remains bound after project switch',function()
  local h,api,cfg,sources,commands,switch,stops=rig(); assert(h:start(slot(),'')); switch(); assert(not h:preflight()); h:stop(); eq(stops(),1); h:restore()
end)
test('adapter rejects pre-existing recording and zero armed tracks',function()
  local h,api=rig(); api.GetPlayStateEx=function() return 5 end; assert(not h:preflight()); api.GetPlayStateEx=function() return 0 end; api.CountTracks=function() return 0 end; assert(not h:preflight())
end)
test('ordinary playback is stopped before seeking and recording',function()
  for _,playstate in ipairs{1,2,3} do
    local h,api,cfg,sources,commands=rig(); local playing=true; local events={}
    local state,stop,seek,record=api.GetPlayStateEx,api.OnStopButtonEx,api.SetEditCurPos2,api.Main_OnCommandEx
    api.GetPlayStateEx=function(p) return playing and playstate or state(p) end
    api.OnStopButtonEx=function(p) events[#events+1]='stop'; playing=false; stop(p) end
    api.SetEditCurPos2=function(...) events[#events+1]='seek'; seek(...) end
    api.Main_OnCommandEx=function(...) events[#events+1]='record'; record(...) end
    assert(h:preflight()); eq(#events,0); assert(h:start(slot(),''))
    eq(table.concat(events,','),'stop,seek,record'); eq(#commands,1)
  end
end)
test('external recording is never stopped or taken over even after preflight',function()
  local h,api,cfg,sources,commands=rig(); assert(h:preflight())
  api.GetPlayStateEx=function() return 5 end
  api.OnStopButtonEx=function() error('Must not stop an external recording') end
  assert(not h:start(slot(),'')); eq(#commands,0); eq(cfg.RECORD_PATH,'original')
end)
test('failed playback stop prevents the recording command',function()
  local h,api,cfg,sources,commands=rig(); api.GetPlayStateEx=function() return 1 end
  api.OnStopButtonEx=function() end
  local ok,err=h:start(slot(),''); assert(not ok and err:find('Playback could not be stopped')); eq(#commands,0)
  h:restore(); eq(cfg.RECORD_PATH,'original')
end)
test('adapter rejects disconnected device, loops and MIDI inputs',function()
  local h,api=rig(); api.GetAudioDeviceInfo=function() return false,'' end; assert(not h:preflight()); api.GetAudioDeviceInfo=function() return true,'48000' end
  api.GetSetRepeatEx=function() return 1 end; assert(not h:preflight()); api.GetSetRepeatEx=function() return 0 end
  api.GetMediaTrackInfo_Value=function(_,k) return k=='I_RECARM' and 1 or (k=='I_RECINPUT' and 4096 or 0) end; assert(not h:preflight())
end)
test('native folder picker selects, cancels and reports missing extension',function()
  local h,api=rig(); local path,err=h:choose_folder(''); eq(path,nil); assert(err:find('js_ReaScriptAPI'))
  api.JS_Dialog_BrowseForFolder=function(title,initial) eq(initial,root); return 1,root..'/Selected folder' end
  eq(h:choose_folder(''),root..'/Selected folder')
  api.JS_Dialog_BrowseForFolder=function() return 0,'' end
  path,err=h:choose_folder(''); eq(path,nil); eq(err,nil)
  api.JS_Dialog_BrowseForFolder=function() return -1,'' end
  path,err=h:choose_folder(''); eq(path,nil); assert(err)
end)
test('write failure prevents start',function()
  local h,api,cfg,sources,commands=rig(); h.writable=function() return nil,'Disk unavailable' end; assert(not h:start(slot(),'')); eq(#commands,0); eq(cfg.RECORD_PATH,'original')
end)
test('continuous host creates linked regions and captures original source positions',function()
  local h,api,cfg,sources,commands=rig(); local st=C.new()
  local a=slot('Band A'); a.finish=a.start+2
  local b=slot('Band B'); b.start=a.start+4; b.finish=a.start+6
  assert(C.apply(st,{a,b})); local regions={}
  api.AddProjectMarker2=function(project,isregion,pos,finish,name)
    assert(isregion); local id=#regions+1; regions[id]={pos=pos,finish=finish,name=name}; return id
  end
  api.EnumProjectMarkers3=function(_,i) local r=regions[i+1]; if not r then return 0 end; return 1,true,r.pos,r.finish,r.name,i+1,0 end
  api.GetTrackName=function() return true,'Input' end; api.GetTrackGUID=function() return '{track}' end
  api.GetMediaItemInfo_Value=function(_,key) return key=='D_POSITION' and 70200 or 6 end
  api.GetMediaItemTakeInfo_Value=function(_,key) return key=='D_PLAYRATE' and 1 or 0 end
  local e=E.new(st,h); e:watch(a.start-10); e:tick(a.start,0)
  eq(#commands,1); eq(#regions,2); eq(regions[1].pos,70200); eq(regions[2].pos,70204)
  eq(#st.captures,1); eq(st.captures[1].bands[2].region,2)
  e:tick(a.start+3,3); eq(h:recording(),true)
  local path=cfg.RECORD_PATH..'/input.wav'; write(path,'recorded audio'); sources[1]=path
  e:tick(a.start+6,6); eq(h:recording(),false); eq(#commands,1)
  eq(st.slots[1].status,'Completed'); eq(st.slots[2].status,'Completed')
  local c=assert(C.deserialize(C.serialize(st))).captures[1]
  eq(c.files[1].position,70200); eq(c.files[1].length,6); eq(c.files[1].offset,0)
  eq(c.files[1].path,path:sub(#root+2)); eq(cfg.RECORD_PATH,'original')
end)
test('full collapsed UI executes actual scheduled start and stop',function()
  local h,api,cfg,sources,commands=rig(); local p=api.EnumProjects(-1); local st=C.new(); st.mode='separate'; assert(C.apply(st,{slot('Loop test')}))
  local now=st.slots[1].start-10; local queue,exits,ext={},{},{}
  local noop=function() end
  api.GetExtState=function(_,k) return ext[k] or '' end; api.SetExtState=function(_,k,v) ext[k]=v end; api.DeleteExtState=function(_,k) ext[k]=nil end
  api.GetProjExtState=function() return 1,C.serialize(st) end; api.SetProjExtState=noop
  api.ImGui_CreateContext=function() return {} end; api.ImGui_SetNextWindowSize=noop; api.ImGui_Cond_FirstUseEver=function() return 0 end
  api.ImGui_ConfigFlags_NavEnableKeyboard=function() return 1 end
  api.ImGui_SetNextWindowSizeConstraints=noop; api.ImGui_PushStyleVar=noop; api.ImGui_PopStyleVar=noop
  for _,key in ipairs({'WindowPadding','FramePadding','ItemSpacing','CellPadding','FrameRounding'}) do api['ImGui_StyleVar_'..key]=function() return 0 end end
  api.ImGui_Begin=function() return false,true end; api.ImGui_End=function() error('Collapsed windows must not call End') end
  api.atexit=function(fn) exits[#exits+1]=fn end; api.defer=function(fn) queue[#queue+1]=fn end; api.time_precise=function() return now end
  api.ShowMessageBox=function(message) error(message) end
  local oldnew=E.new; local oldhost=H.new; local oldtime=os.time
  H.new=function() return h end
  E.new=function(state,host) local e=oldnew(state,host); assert(e:enable(now)); return e end
  os.time=function(t) if t then return oldtime(t) end; return now end
  local ok,err=pcall(function()
    M.run(api); eq(#queue,1); eq(#commands,0)
    now=now+10; table.remove(queue,1)(); eq(#commands,1)
    local file=cfg.RECORD_PATH..'/live.wav'; write(file,'recorded audio'); sources[1]=file
    now=now+3600; table.remove(queue,1)(); eq(h:recording(),false); eq(cfg.RECORD_PATH,'original')
    local f=assert(io.open(root..'/session.rpp.jg-scheduler','rb')); local saved=assert(C.deserialize(f:read('*a'))); f:close(); eq(saved.slots[1].status,'Completed')
    for _,exit in ipairs(exits) do exit() end
  end)
  E.new=oldnew; H.new=oldhost; os.time=oldtime
  files[root..'/session.rpp.jg-scheduler']=true
  assert(ok,err)
end)
test('single schedule view, settings, activity window and editor preserve data and native stacks',function()
  os.remove(root..'/session.rpp.jg-scheduler')
  local h,api=rig(); local st=C.new(); st.mode='separate'; assert(C.apply(st,{slot('Visible test')}))
  st.templates={{name='Template',start='19:30',finish='20:30',open=false,pre='0',post='0',enddays=0}}
  local ext,exits={},{}; local windows,disabled,ids,tables=0,0,0,0
  local clicked,typed,tab,queued=nil,{},nil,nil
  local shown={}
  local function record(_,label) shown[label]=true end
  local noop=function() end
  api.GetExtState=function(_,k) return ext[k] or '' end; api.SetExtState=function(_,k,v) ext[k]=v end; api.DeleteExtState=function(_,k) ext[k]=nil end
  api.GetProjExtState=function() return 1,C.serialize(st) end; api.SetProjExtState=noop
  api.ImGui_CreateContext=function() return {} end; api.ImGui_SetNextWindowSize=noop; api.ImGui_Cond_FirstUseEver=function() return 0 end
  api.ImGui_ConfigFlags_NavEnableKeyboard=function() return 1 end
  api.ImGui_SetNextWindowSizeConstraints=noop; api.ImGui_PushStyleVar=noop; api.ImGui_PopStyleVar=noop
  for _,key in ipairs({'WindowPadding','FramePadding','ItemSpacing','CellPadding','FrameRounding'}) do api['ImGui_StyleVar_'..key]=function() return 0 end end
  api.ImGui_Begin=function() windows=windows+1; return true,true end; api.ImGui_End=function() windows=windows-1; assert(windows>=0) end
  local locks={}
  api.ImGui_BeginDisabled=function(_,locked) disabled=disabled+1; locks[disabled]=locked end
  api.ImGui_EndDisabled=function() locks[disabled]=nil; disabled=disabled-1; assert(disabled>=0) end
  api.ImGui_BeginTable=function() tables=tables+1; return true end; api.ImGui_EndTable=function() tables=tables-1 end
  api.ImGui_PushID=function() ids=ids+1 end; api.ImGui_PopID=function() ids=ids-1 end
  for _,key in ipairs({'TextWrapped','Separator','SameLine','TableSetupColumn','TableHeadersRow','TableNextColumn','TableNextRow','TableSetupScrollFreeze','Text','TextColored','PushFont','PopFont','SetNextItemWidth'}) do api['ImGui_'..key]=noop end
  for _,key in ipairs({'TableFlags_Borders','TableFlags_RowBg','TableFlags_Resizable','TreeNodeFlags_DefaultOpen','TableFlags_ScrollY','TableFlags_SizingStretchProp','TableFlags_SizingStretchSame','TableColumnFlags_WidthFixed','TableColumnFlags_WidthStretch','SelectableFlags_SpanAllColumns','SelectableFlags_AllowDoubleClick'}) do api['ImGui_'..key]=function() return 0 end end
  local settings_open=false
  api.ImGui_CollapsingHeader=function(_,label)
    assert(label~='Selected slot details' and label~='Recording help' and label~='Templates')
    if label=='Recording settings' then if clicked==label then settings_open=not settings_open end; return settings_open end
    return false
  end
  api.ImGui_TextWrapped=record; api.ImGui_Text=record
  api.ImGui_Checkbox=function(_,label,value) assert(label~='Open end'); return false,value end
  api.ImGui_InputText=function(_,key,value) shown[key]=true; return typed[key]~=nil,typed[key] or value end
  api.ImGui_Combo=api.ImGui_Checkbox
  api.ImGui_Button=function(_,label) shown[label]=true; for _,locked in pairs(locks) do if locked then return false end end; return clicked==label end
  api.ImGui_Selectable=function(_,label) assert(label~='Schedule' and label~='Setup' and label~='Activity'); return tab==label end
  local double_click=false
  api.ImGui_IsMouseDoubleClicked=function(_,button) eq(button,0); return double_click end
  api.ImGui_GetContentRegionAvail=function() return 900,500 end
  api.GetProjectName=function() return 'session.rpp' end
  api.atexit=function(fn) exits[#exits+1]=fn end; api.defer=function(fn) queued=fn end; api.time_precise=function() return 0 end
  api.ShowMessageBox=function(message) error(message) end
  local old=H.new; H.new=function() return h end
  local original_engine=E.new; local captured
  E.new=function(state,host) captured=original_engine(state,host); return captured end
  local ok,err=pcall(function()
    M.run(api)
    assert(shown['Add slot'] and not shown['##name'] and not shown['Export log'])
    assert(not shown['Review setup'] and not shown['Select a slot to edit, duplicate or inspect its details.'])
    local function frame(button,values,selected)
      clicked,typed,tab,shown=button,values or {},selected,{}
      assert(queued)(); eq(windows,0); eq(disabled,0); eq(ids,0); eq(tables,0)
    end
    frame('Add slot'); frame()
    assert(shown['##name'] and shown['##start'] and not shown['##pre'])
    frame('Save slot',{['##name']='Future capture',['##date']='301102',['##enddate']='301102',['##start']='21:00',['##finish']='22:00'})
    local f=assert(io.open(root..'/session.rpp.jg-scheduler','rb')); local saved=assert(C.deserialize(f:read('*a'))); f:close()
    eq(#saved.slots,2); eq(saved.slots[2].name,'Future capture'); eq(captured.state.enabled,true)
    frame('Add slot'); frame()
    frame('Save slot',{['##name']='Overlap attempt',['##date']='301102',['##enddate']='301102',['##start']='21:30',['##finish']='22:30'})
    assert(shown['Overlap: Future capture / Overlap attempt. Adjust the times before saving.'], 'Save rejection must be visible immediately beside the form action')
    eq(#captured.state.slots,2); frame(); assert(shown['Shorten and save'])
    captured.state.revision=captured.state.revision+1
    frame('Shorten and save'); eq(#captured.state.slots,2)
    assert(shown['The schedule changed. Save again to review the overlap.'])
    frame('Save slot'); frame('Shorten and save'); frame()
    eq(#captured.state.slots,3); assert(shown['Add slot'] and not shown['##name'])
    eq(captured.state.slots[2].finish,captured.state.slots[3].start)
    frame('Undo'); eq(#captured.state.slots,2)

    frame('Cancel')
    frame(); assert(not shown['Pause schedule'] and not shown['Resume schedule']); eq(captured.state.enabled,true)
    frame('Add slot'); frame()
    frame('Save slot',{['##name']='Later capture',['##date']='301102',['##enddate']='301102',['##start']='23:00',['##finish']='23:30'})
    eq(captured.state.enabled,true)
    frame('Recording settings'); assert(shown['Add slot'] and shown['##recording_root'] and shown['Choose folder...'] and not shown['##name'] and not shown['##recording_mode'])
    frame('Recording settings'); frame('Activity log'); assert(shown['Export log'] and shown['Add slot'] and not shown['##recording_root'])
    local normal_begin=api.ImGui_Begin
    api.ImGui_Begin=function(_,title) windows=windows+1; return true,not title:find('###Recording Scheduler Activity',1,true) end
    frame(); api.ImGui_Begin=normal_begin
    frame(); assert(shown['Add slot'] and not shown['Export log'] and not shown['##name'])
    frame(nil,nil,'Future capture##slot'); frame(); assert(not shown['##name'])
    double_click=true; frame(nil,nil,'Future capture##slot'); double_click=false; frame()
    assert(shown['Save changes'])
    frame('Cancel',{['##name']='Discarded edit'}); frame()
    f=assert(io.open(root..'/session.rpp.jg-scheduler','rb')); saved=assert(C.deserialize(f:read('*a'))); f:close()
    eq(saved.slots[2].name,'Future capture')
    -- A failed slot may be removed from the plan without touching recorded audio.
    captured.state.slots[2].status='Failed'
    double_click=true; frame(nil,nil,'Future capture##slot'); double_click=false; frame()
    assert(not shown['##name'], 'Double-click must not edit recording history')
    local audio=root..'/keep-recording.wav'; write(audio,'keep this recording')
    frame(nil,nil,'Future capture##slot'); frame('Delete')
    eq(#captured.state.slots,2)
    local recording=assert(io.open(audio,'rb')); eq(recording:read('*a'),'keep this recording'); recording:close()
    frame('Undo'); eq(#captured.state.slots,3)
    local project_file=h.project_file
    h.project_file=function() return '' end
    frame('Add slot'); frame()
    frame('Save slot',{['##name']='Unsaved capture',['##date']='301103',['##enddate']='301103',['##start']='21:00',['##finish']='22:00'})
    eq(#captured.state.slots,3)
    assert(shown['Save the REAPER project first (Cmd/Ctrl+S), then save the slot.'])
    frame(); assert(shown['##name'], 'Rejected draft must stay open')
    h.project_file=project_file
    frame('Save slot'); eq(#captured.state.slots,4)
    frame(); eq(captured.state.enabled,true)
    frame('Add slot'); frame('Save slot',{['##name']='Open end test',['##date']='301104',['##enddate']='301104',['##start']='21:00',['##finish']=''})
    frame(); eq(captured.state.slots[#captured.state.slots].finish,nil); assert(shown['Add slot'] and not shown['##name'])
    frame('Undo')
    frame('Recording settings')
    api.ImGui_Combo=function(_,key,value) return key=='##mode',0 end
    frame(); eq(captured.state.mode,'continuous')
    api.ImGui_Combo=api.ImGui_Checkbox
    frame('Recording settings')
    captured.state.captures={{id='ui',wall=0,position=0,folder=root,bands={{region=1,start=0,name='Band'}},files={}}}
    api.EnumProjectMarkers3=function(_,i) if i>0 then return 0 end; return 1,true,0,10,'Band renamed',1,0 end
    frame('Export band folders...'); frame()
    assert(shown['Export now']); frame('Cancel')
    captured.state.enabled=true
    api.ImGui_Begin=function() windows=windows+1; return true,false end
    frame()
    eq(captured.state.enabled,false)
    assert(not shown['Stop and close'])
  end)
  H.new=old; E.new=original_engine
  for _,f in ipairs(exits) do f() end
  assert(ok,err); eq(windows,0); eq(disabled,0); eq(tables,0); eq(ids,0)
  files[root..'/session.rpp.jg-scheduler']=true
end)
for path in pairs(files) do os.remove(path) end
for path in pairs(dirs) do os.remove(path) end
os.remove(root)
print(tests..' host integration tests passed.')
