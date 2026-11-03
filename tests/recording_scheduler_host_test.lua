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
test('adapter accepts MIDI input but rejects disconnected device and loops',function()
  local h,api=rig(); api.GetAudioDeviceInfo=function() return false,'' end; assert(not h:preflight()); api.GetAudioDeviceInfo=function() return true,'48000' end
  api.GetSetRepeatEx=function() return 1 end; assert(not h:preflight()); api.GetSetRepeatEx=function() return 0 end
  api.GetMediaTrackInfo_Value=function(_,k) return k=='I_RECARM' and 1 or (k=='I_RECINPUT' and 4096 or 0) end; assert(h:preflight())
end)
test('write failure prevents start',function()
  local h,api,cfg,sources,commands=rig(); h.writable=function() return nil,'Disk unavailable' end; assert(not h:start(slot(),'')); eq(#commands,0); eq(cfg.RECORD_PATH,'original')
end)
test('legacy continuous host creates linked regions and captures original source positions',function()
  local h,api,cfg,sources,commands=rig(); local st=C.new(); st.mode='continuous'
  local a=slot('Band A'); a.finish=a.start+2
  local b=slot('Band B'); b.start=a.start+4; b.finish=a.start+6
  assert(C.apply(st,{a,b})); local regions={}
  api.AddProjectMarker2=function(project,isregion,pos,finish,name)
    assert(isregion); local id=#regions+1; regions[id]={pos=pos,finish=finish,name=name}; return id
  end
  api.EnumProjectMarkers3=function(_,i) local r=regions[i+1]; if not r then return 0 end; return 1,true,r.pos,r.finish,r.name,i+1,0 end
  api.SetProjectMarker3=function(_,id,isregion,pos,finish,name)
    assert(isregion); regions[id]={pos=pos,finish=finish,name=name}; return true
  end
  api.GetTrackName=function() return true,'Input' end; api.GetTrackGUID=function() return '{track}' end
  api.GetMediaItemInfo_Value=function(_,key) return key=='D_POSITION' and 70200 or 8 end
  api.GetMediaItemTakeInfo_Value=function(_,key) return key=='D_PLAYRATE' and 1 or 0 end
  local e=E.new(st,h); e:watch(a.start-10); e:tick(a.start,0)
  eq(#commands,1); eq(#regions,2); eq(regions[1].pos,70200); eq(regions[2].pos,70204)
  eq(#st.captures,1); eq(st.captures[1].bands[2].region,2)
  local draft={}; for k,v in pairs(st.slots[1]) do draft[k]=v end
  draft.name='Band A revised'; draft.finish=a.start+3
  assert(e:edit_live(st.slots[1].id,draft,a.start+1)); eq(regions[1].finish,70203); eq(regions[1].name,'Band A revised')
  e:tick(a.start+4,4); eq(h:recording(),true)
  draft={}; for k,v in pairs(st.slots[2]) do draft[k]=v end; draft.finish=a.start+8
  assert(e:edit_live(st.slots[2].id,draft,a.start+4)); eq(regions[2].finish,70208)
  eq(e.active.finish,a.start+8)
  local path=cfg.RECORD_PATH..'/input.wav'; write(path,'recorded audio'); sources[1]=path
  e:tick(a.start+6,6); eq(h:recording(),true)
  e:tick(a.start+8,8); eq(h:recording(),false); eq(#commands,1)
  eq(st.slots[1].status,'Completed'); eq(st.slots[2].status,'Completed')
  local c=assert(C.deserialize(C.serialize(st))).captures[1]
  eq(c.files[1].position,70200); eq(c.files[1].length,8); eq(c.files[1].offset,0)
  eq(c.files[1].path,path:sub(#root+2)); eq(cfg.RECORD_PATH,'original')
end)
test('appended band region and confirmed previous end update together',function()
  local h,api=rig(); local regions={{pos=100,finish=101,name='First'}}
  api.EnumProjectMarkers3=function(_,i) local v=regions[i+1]; if not v then return 0 end; return 1,true,v.pos,v.finish,v.name,i+1,0 end
  api.AddProjectMarker2=function(_,_,pos,finish,name) regions[#regions+1]={pos=pos,finish=finish,name=name}; return #regions end
  api.SetProjectMarker3=function(_,id,_,pos,finish,name) regions[id]={pos=pos,finish=finish,name=name}; return true end
  local c={position=100,wall=1000,bands={{region=1,start=1000,name='First',open=true}}}
  assert(h:append_band(c,{start=1010,finish=1020,name='Second'},{start=1000,name='First'}))
  eq(#c.bands,2); eq(regions[1].finish,110); eq(regions[2].pos,110); eq(regions[2].finish,120)
  eq(c.bands[1].open,false)
end)
test('manual stop closes only open-ended band regions and preserves edited names',function()
  local h,api=rig(); local updated={}
  api.EnumProjectMarkers3=function(_,i)
    if i==0 then return 1,true,100,101,'Edited band name',7,123 end
    if i==1 then return 1,true,200,220,'Fixed band',8,456 end
    return 0
  end
  api.SetProjectMarker3=function(_,id,isregion,pos,finish,name,color)
    updated[#updated+1]={id=id,finish=finish,name=name,color=color}; return true
  end
  h:finish_regions({position=100,wall=1000,bands={{region=7,open=true},{region=8,open=false}}},1042)
  eq(#updated,1); eq(updated[1].id,7); eq(updated[1].finish,142)
  eq(updated[1].name,'Edited band name'); eq(updated[1].color,123)
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
  for _,key in ipairs({'TextWrapped','Separator','SameLine','TableSetupColumn','TableHeadersRow','TableNextColumn','TableNextRow','TableSetupScrollFreeze','Text','TextColored','PushFont','PopFont','SetNextItemWidth','SetKeyboardFocusHere'}) do api['ImGui_'..key]=noop end
  for _,key in ipairs({'TableFlags_Borders','TableFlags_RowBg','TableFlags_Resizable','TreeNodeFlags_DefaultOpen','TableFlags_ScrollY','TableFlags_SizingStretchProp','TableFlags_SizingStretchSame','TableColumnFlags_WidthFixed','TableColumnFlags_WidthStretch','SelectableFlags_SpanAllColumns','SelectableFlags_AllowDoubleClick'}) do api['ImGui_'..key]=function() return 0 end end
  api.ImGui_CollapsingHeader=function(_,label)
    assert(label~='Selected slot details' and label~='Recording help' and label~='Templates')
    assert(label~='Recording folder' and label~='Recording settings', 'The recording folder must not require expanding')
    return false
  end
  api.ImGui_TextWrapped=record; api.ImGui_Text=record
  api.ImGui_Checkbox=function(_,label,value) assert(label~='Open end'); return false,value end
  local last_input,focused_input,seen_values=nil,'##finish',{}
  api.ImGui_IsItemFocused=function() return last_input==focused_input and clicked~='Enter' and clicked~='KeypadEnter' end
  api.ImGui_IsItemDeactivated=function() return last_input==focused_input and (clicked=='Enter' or clicked=='KeypadEnter') end
  local main_focused=true
  api.ImGui_IsWindowFocused=function() return main_focused end
  api.ImGui_FocusedFlags_ChildWindows=function() return 0 end
  api.ImGui_Key_Enter=function() return 'Enter' end
  api.ImGui_Key_KeypadEnter=function() return 'KeypadEnter' end
  api.ImGui_IsKeyPressed=function(_,key,repeat_key) eq(repeat_key,false); return clicked==key end
  api.ImGui_InputTextFlags_EnterReturnsTrue=function() return 1 end
  api.ImGui_InputText=function(_,key,value,flags)
    last_input=key; seen_values[key]=value
    shown[key]=true; for _,locked in pairs(locks) do if locked then return false,value end end
    if flags==1 then
      local submitted=clicked=='Enter' and key==focused_input
      return submitted,submitted and (typed[key] or value) or value
    end
    return typed[key]~=nil,typed[key] or value
  end
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
    assert(not shown['Separate slots / individual folders'])
    assert(not shown['Review setup'] and not shown['Select a slot to edit, duplicate or inspect its details.'])
    local function frame(button,values,selected)
      clicked,typed,tab,shown=button,values or {},selected,{}
      assert(queued)(); eq(windows,0); eq(disabled,0); eq(ids,0); eq(tables,0)
    end
    main_focused=false; frame('Enter'); assert(not shown['##name'])
    main_focused=true; frame('KeypadEnter'); assert(shown['##name']); eq(#captured.state.slots,1)
    frame('Cancel'); frame('Enter'); assert(shown['##name']); eq(#captured.state.slots,1)
    frame()
    assert(shown['##name'] and shown['##start'] and not shown['##pre'])
    frame(nil,{['##name']='Future capture',['##date']='301102',['##enddate']='301102'})
    focused_input='##start'; frame(nil,{['##start']='2100'})
    focused_input='##finish'; frame('Tab')
    eq(seen_values['##start'],'2100', 'Tab must retain the typed start time')
    frame(nil,{['##finish']='22:00'}); frame('Enter')
    local f=assert(io.open(root..'/session.rpp.jg-scheduler','rb')); local saved=assert(C.deserialize(f:read('*a'))); f:close()
    eq(#saved.slots,2); eq(saved.slots[2].name,'Future capture'); eq(captured.state.enabled,true)
    local adjacent_draft={['##name']='Adjacent',['##date']='301102',['##enddate']='301102',['##start']='22:00',['##finish']='22:30'}
    frame('Add slot'); frame('Enter',adjacent_draft); frame()
    eq(#captured.state.slots,2); assert(shown['Save anyway'])
    assert(shown['These slots meet without a gap. Starting a new recording file will cause a brief interruption.'])
    frame('Enter'); eq(#captured.state.slots,2)
    captured.state.revision=captured.state.revision+1
    frame('Save anyway'); eq(#captured.state.slots,2)
    assert(shown['The schedule changed. Save again to review adjacent slots.'])
    frame('Save slot'); frame('Save anyway'); frame()
    eq(#captured.state.slots,3); assert(shown['Add slot'] and not shown['##name'])
    frame('Undo'); eq(#captured.state.slots,2)
    frame('Add slot'); frame('Save slot',adjacent_draft); frame('Keep editing')
    eq(#captured.state.slots,2)
    frame(nil,{['##start']='22:05'}); assert(not shown['Save anyway'])
    frame('Enter'); eq(#captured.state.slots,3)
    frame('Undo'); eq(#captured.state.slots,2)
    frame('Add slot'); frame()
    frame('Save slot',{['##name']='Overlap attempt',['##date']='301102',['##enddate']='301102',['##start']='21:30',['##finish']='22:30'})
    assert(shown['Overlap: Future capture / Overlap attempt. Adjust the times before saving.'], 'Save rejection must be visible immediately beside the form action')
    eq(#captured.state.slots,2); frame(); assert(shown['Shorten and save'])
    frame('Enter'); eq(#captured.state.slots,2); assert(shown['Shorten and save'])
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
    frame(); assert(shown['Add slot'] and not shown['##recording_root'] and not shown['Choose folder...'] and not shown['##name'] and not shown['##recording_mode'])
    frame('Activity log'); assert(shown['Export log'] and shown['Add slot'] and not shown['##recording_root'])
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
    frame('Enter',{['##name']='Unsaved capture',['##date']='301103',['##enddate']='301103',['##start']='21:00',['##finish']='22:00'})
    eq(#captured.state.slots,3)
    assert(shown['Save the REAPER project first (Cmd/Ctrl+S), then save the slot.'])
    frame(); assert(shown['##name'], 'Rejected draft must stay open')
    h.project_file=project_file
    frame('Save slot'); eq(#captured.state.slots,4)
    frame(); eq(captured.state.enabled,true)
    local live=captured.state.slots[#captured.state.slots]
    local original_start=live.start
    api.SetEditCurPos2=function() end
    captured:start_session(live,os.time())
    double_click=true; frame(nil,nil,live.name..'##slot'); double_click=false; frame()
    assert(shown['Save changes'] and not shown['Extend by 5 min'])
    frame('Save changes',{['##name']='Live edited',['##start']='23:59',['##finish']='22:10'})
    frame(); eq(live.start,original_start); eq(live.name,'Live edited')
    assert(shown['Add slot'] and not shown['##name']); eq(h:recording(),true)
    local has_countdown=false; for label in pairs(shown) do if label:match('^%d+:%d%d:%d%d left$') then has_countdown=true end end
    assert(has_countdown, 'Running slot must show remaining time in its row')
    captured:stop(os.time()+1)
    local expected_default='Slot '..captured.state.next_id
    frame('Add slot'); frame(nil,{['##name']='',['##date']='301104',['##enddate']='301104',['##start']='21:00',['##finish']=''})
    focused_input=nil; frame('Enter'); assert(shown['##name'], 'Enter outside a field must not submit')
    focused_input='##start'; frame('KeypadEnter')
    frame(); eq(captured.state.slots[#captured.state.slots].name,expected_default); eq(captured.state.slots[#captured.state.slots].finish,nil); assert(shown['Add slot'] and not shown['##name'])
    frame('Undo')
    api.ImGui_Combo=function(_,key,value) return key=='##mode',0 end
    frame(); eq(captured.state.mode,'separate'); assert(not shown['##mode'] and not shown['Recording mode'])
    api.ImGui_Combo=api.ImGui_Checkbox
    captured.state.captures={{id='ui',wall=0,position=0,folder=root,bands={{region=1,start=0,name='Band'}},files={}}}
    frame()
    assert(shown['Add slot'] and not shown['Export band folders...'] and not shown['Export now'])
    eq(#captured.state.captures,1)
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
test('pause and resume map source boundaries with the processing cursor',function()
  local state,position=5,103.25
  local track={}; local h=H.new({
    GetPlayStateEx=function() return state end,
    Main_OnCommandEx=function(cmd) eq(cmd,1008); state=state==5 and 6 or 5; if state==5 then position=103.2 end end,
    GetPlayPosition2Ex=function() return position end,
    GetAudioDeviceInfo=function() return true,'48000' end,
    CountTrackMediaItems=function() return 0 end,
  },{})
  h.selected=function() return true end; h.tracks=function() return {track} end; h.expected={track}
  local c={position=100,wall=1000,recorded_offset=0,resume_position=100,segments={{offset=0,position=100}}}
  assert(h:pause_capture(c)); eq(c.recorded_offset,3.25); eq(state,6)
  assert(h:resume_capture(c,1010)); eq(c.segments[2].offset,3.25); eq(c.segments[2].position,110)
  position=106.2; assert(h:pause_capture(c)); assert(math.abs(c.recorded_offset-6.25)<1e-9)
end)
test('shared source items split across file boundaries without rendering or data loss',function()
  local items={{position=100,length=3,offset=0,path='a.wav'},{position=103,length=3,offset=0,path='b.wav'}}
  local api={CountTrackMediaItems=function() return #items end,GetTrackMediaItem=function(_,i) return items[i+1] end,
    GetTake=function(item) return item end,CountTakes=function() return 1 end,
    GetMediaItemTake_Source=function(t) return t end,GetMediaSourceFileName=function(t) return t.path end,
    GetMediaItemTakeInfo_Value=function(t,k) return k=='D_PLAYRATE' and 1 or t.offset end,
    GetMediaItemInfo_Value=function(t,k) return k=='D_POSITION' and t.position or t.length end,
    SetMediaItemInfo_Value=function(t,k,v) if k=='D_POSITION' then t.position=v end; return true end,
    SplitMediaItem=function(t,at)
      local length=at-t.position; local right={position=at,length=t.length-length,offset=t.offset+length,path=t.path}
      t.length=length; items[#items+1]=right; return right
    end,
    Undo_BeginBlock2=function() end,Undo_EndBlock2=function() end,UpdateArrange=function() end,
  }
  local h=H.new(api,{}); h.expected={{}}; h.result_files={'a.wav','b.wav'}
  local c={segments={{offset=0,position=100},{offset=2,position=110},{offset=4,position=120}}}
  assert(h:place_capture(c)); eq(#items,4)
  table.sort(items,function(a,b) return a.position<b.position end)
  eq(items[1].position,100); eq(items[1].length,2)
  eq(items[2].position,110); eq(items[2].offset,2); eq(items[2].length,1)
  eq(items[3].position,111); eq(items[3].offset,0); eq(items[3].length,1)
  eq(items[4].position,120); eq(items[4].offset,1); eq(items[4].length,2)
end)
test('generated region ends fit actual captured audio without moving manual boundaries',function()
  local h,api=rig()
  local regions={[1]={position=100,finish=103,name='Automatic',color=0},[2]={position=110,finish=114,name='Manual',color=0}}
  h.regions=function() return regions end
  api.SetProjectMarker3=function(_,id,_,position,finish,name) regions[id]={position=position,finish=finish,name=name}; return true end
  local c={position=100,wall=1000,bands={{region=1,position=100,finish=103},{region=2,position=110,finish=113}},files={
    {track='t',position=100,length=2.997},{track='t',position=110,length=2.997}}}
  h:finish_regions(c,1013)
  eq(regions[1].finish,102.997); eq(regions[2].finish,114)
end)
test('resume rejects changed sample rate before touching transport',function()
  local h=H.new({GetPlayStateEx=function() return 6 end,GetAudioDeviceInfo=function() return true,'96000' end,
    Main_OnCommandEx=function() error('Must not resume') end}, {})
  local t={}; h.expected={t}; h.tracks=function() return {t} end; h.selected=function() return true end; h.capture_rate=48000
  local ok,err=h:resume_capture({},1000); assert(not ok and err:find('sample rate'))
end)
test('MIDI verification requires new events and saves after restoring the destination',function()
  local h,api,cfg,sources=rig()
  api.GetMediaTrackInfo_Value=function(_,key) return key=='I_RECARM' and 1 or (key=='I_RECINPUT' and 4096 or 0) end
  api.TakeIsMIDI=function() return true end
  api.GetSetMediaItemTakeInfo_String=function(take) return true,take end
  local count=1; api.MIDI_CountEvts=function() return 1,0,count,0 end -- CC-only recording is valid.
  api.IsProjectDirty=function() return 0 end
  local saves=0; api.Main_SaveProject=function(project,force) eq(project,h.project); eq(force,false); eq(cfg.RECORD_PATH,'original'); saves=saves+1 end
  assert(h:preflight()); assert(h:start(slot(),'')); h:stop()
  assert(not h:verify()); sources[1]='new-midi-take'
  count=0; assert(not h:verify()); count=1; assert(h:verify())
  h:restore(); assert(h:save_recorded_midi()); eq(saves,1); assert(h:save_recorded_midi()); eq(saves,1)
end)
test('existing MIDI and failed project saves cannot be reported as successful new recordings',function()
  local h,api,cfg,sources=rig(); sources[1]='old-midi-take'
  api.TakeIsMIDI=function() return true end
  api.GetSetMediaItemTakeInfo_String=function(take) return true,take end
  api.MIDI_CountEvts=function() return 1,3,0,0 end
  api.GetMediaTrackInfo_Value=function(_,key) return key=='I_RECARM' and 1 or (key=='I_RECINPUT' and 4096 or 0) end
  assert(h:start(slot(),'')); h:stop(); assert(not h:verify())
  sources[2]='new-midi-take'; assert(h:verify()); h:restore()
  api.Main_SaveProject=function() end; api.IsProjectDirty=function() return 1 end
  local ok,err=h:save_recorded_midi(); assert(not ok and err:find('Save the project'))
end)
test('mixed audio and MIDI sessions require a valid result on both types of track',function()
  local h,api=rig(); local audio,midi={},{}
  local path=root..'/mixed.wav'; write(path,'audio data')
  local audio_item={path=path}; local midi_item={midi=true,guid='midi'}
  audio.items={audio_item}; midi.items={midi_item}
  h.expected={audio,midi}; h.expected_settings={[audio]={input=0},[midi]={input=4096}}; h.saved={newpath=root}
  api.ValidatePtr2=function() return true end
  api.CountTrackMediaItems=function(t) return #t.items end
  api.GetTrackMediaItem=function(t,i) return t.items[i+1] end
  api.TakeIsMIDI=function(t) return t.midi or false end
  api.GetMediaSourceFileName=function(t) return t.path or '' end
  api.GetSetMediaItemTakeInfo_String=function(t) return true,t.guid end
  api.MIDI_CountEvts=function() return 1,1,0,0 end
  assert(h:verify())
  audio.items={}; assert(not h:verify())
  audio.items={audio_item}; midi.items={}; assert(not h:verify())
end)
test('slot folders always use the saved RPP directory instead of media path or old overrides',function()
  local h,api,cfg=rig()
  api.GetProjectPathEx=function() error('The recording-media path must not be used') end
  eq(h:root_path('/old/custom/folder'),root)
  assert(h:start(slot(),'old-relative-folder'))
  eq(cfg.RECORD_PATH,root..'/'..C.folder(slot()))
  h:stop(); h:restore(); eq(cfg.RECORD_PATH,'original')
end)
for path in pairs(files) do os.remove(path) end
for path in pairs(dirs) do os.remove(path) end
os.remove(root)
print(tests..' host integration tests passed.')
