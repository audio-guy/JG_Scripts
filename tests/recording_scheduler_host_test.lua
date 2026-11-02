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
    RecursiveCreateDirectory=function(path) dirs[path]=true; assert(os.execute('mkdir -p '..string.format('%q',path))) end,
    genGuid=function() return '{probe}' end,
    GetSetProjectInfo_String=function(project,key,value,set) eq(project,p); if set then cfg[key]=value end; return true,cfg[key] end,
    CountTrackMediaItems=function() return #sources end, GetTrackMediaItem=function(_,i) return sources[i+1] end,
    CountTakes=function() return 1 end, GetTake=function(item) return item end, TakeIsMIDI=function() return false end,
    GetMediaItemTake_Source=function(take) return take end, GetMediaSourceFileName=function(source) return source end, GetMediaSourceLength=function() return 60,false end,
    GetCursorPositionEx=function(project) eq(project,p); return 5 end, GetProjectLength=function(project) eq(project,p); return 100 end,
    SetEditCurPos2=function(project,position) eq(project,p); eq(position,100) end,
    Main_OnCommandEx=function(cmd,_,project) eq(project,p); eq(cmd,1013); rec=true; commands[#commands+1]=cmd end,
    OnStopButtonEx=function(project) eq(project,p); rec=false; stopped=stopped+1 end,
    AddProjectMarker2=function(project) eq(project,p) end, GetPlayPositionEx=function(project) eq(project,p); return 100 end,
  }
  local h=H.new(api,p); h.confirmed=true
  return h,api,cfg,sources,commands,function() selected=other end,function() return stopped end
end
local function slot(name)
  return assert(C.make{name=name or 'Konzert',date='261102',start='19:30',enddate='261102',finish='20:30',pre='0',post='0'})
end

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
test('adapter rejects pre-existing transport and zero armed tracks',function()
  local h,api=rig(); api.GetPlayStateEx=function() return 5 end; assert(not h:preflight()); api.GetPlayStateEx=function() return 0 end; api.CountTracks=function() return 0 end; assert(not h:preflight())
end)
test('adapter rejects disconnected device, loops and MIDI inputs',function()
  local h,api=rig(); api.GetAudioDeviceInfo=function() return false,'' end; assert(not h:preflight()); api.GetAudioDeviceInfo=function() return true,'48000' end
  api.GetSetRepeatEx=function() return 1 end; assert(not h:preflight()); api.GetSetRepeatEx=function() return 0 end
  api.GetMediaTrackInfo_Value=function(_,k) return k=='I_RECARM' and 1 or (k=='I_RECINPUT' and 4096 or 0) end; assert(not h:preflight())
end)
test('write failure prevents start',function()
  local h,api,cfg,sources,commands=rig(); h.writable=function() return nil,'Disk unavailable' end; assert(not h:start(slot(),'')); eq(#commands,0); eq(cfg.RECORD_PATH,'original')
end)
test('full collapsed UI executes actual scheduled start and stop',function()
  local h,api,cfg,sources,commands=rig(); local p=api.EnumProjects(-1); local st=C.new(); assert(C.apply(st,{slot('Loop test')}))
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
test('schedule, setup, activity and editor flows preserve data and native stacks',function()
  os.remove(root..'/session.rpp.jg-scheduler')
  local h,api=rig(); local st=C.new(); assert(C.apply(st,{slot('Visible test')}))
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
  api.ImGui_BeginDisabled=function() disabled=disabled+1 end; api.ImGui_EndDisabled=function() disabled=disabled-1; assert(disabled>=0) end
  api.ImGui_BeginTable=function() tables=tables+1; return true end; api.ImGui_EndTable=function() tables=tables-1 end
  api.ImGui_PushID=function() ids=ids+1 end; api.ImGui_PopID=function() ids=ids-1 end
  for _,key in ipairs({'TextWrapped','Separator','SameLine','TableSetupColumn','TableHeadersRow','TableNextColumn','TableNextRow','TableSetupScrollFreeze','Text','TextColored','PushFont','PopFont','SetNextItemWidth'}) do api['ImGui_'..key]=noop end
  for _,key in ipairs({'TableFlags_Borders','TableFlags_RowBg','TableFlags_Resizable','TreeNodeFlags_DefaultOpen','TableFlags_ScrollY','TableFlags_SizingStretchProp','TableFlags_SizingStretchSame','TableColumnFlags_WidthFixed','TableColumnFlags_WidthStretch','SelectableFlags_SpanAllColumns'}) do api['ImGui_'..key]=function() return 0 end end
  api.ImGui_CollapsingHeader=function() return false end
  api.ImGui_TextWrapped=record; api.ImGui_Text=record
  api.ImGui_Checkbox=function(_,_,value) return false,value end
  api.ImGui_InputText=function(_,key,value) shown[key]=true; return typed[key]~=nil,typed[key] or value end
  api.ImGui_Combo=api.ImGui_Checkbox
  api.ImGui_Button=function(_,label) shown[label]=true; return clicked==label end
  api.ImGui_Selectable=function(_,label) return tab==label end
  api.ImGui_GetContentRegionAvail=function() return 900,500 end
  api.GetProjectName=function() return 'session.rpp' end
  api.atexit=function(fn) exits[#exits+1]=fn end; api.defer=function(fn) queued=fn end; api.time_precise=function() return 0 end
  api.ShowMessageBox=function(message) error(message) end
  local old=H.new; H.new=function() return h end
  local ok,err=pcall(function()
    M.run(api)
    assert(shown['Add slot'] and not shown['##name'] and not shown['Export log'])
    local function frame(button,values,selected)
      clicked,typed,tab,shown=button,values or {},selected,{}
      assert(queued)(); eq(windows,0); eq(disabled,0); eq(ids,0); eq(tables,0)
    end
    frame('Add slot'); frame()
    assert(shown['##name'] and shown['##start'] and not shown['##pre'])
    frame('Add slot',{['##name']='Future capture',['##date']='301102',['##enddate']='301102',['##start']='21:00',['##finish']='22:00'})
    local f=assert(io.open(root..'/session.rpp.jg-scheduler','rb')); local saved=assert(C.deserialize(f:read('*a'))); f:close()
    eq(#saved.slots,2); eq(saved.slots[2].name,'Future capture')
    frame(nil,nil,'Setup'); assert(shown['##recording_root'] and not shown['##name'])
    frame(nil,nil,'Activity'); assert(shown['Export log'] and not shown['##recording_root'])
    frame(nil,nil,'Schedule'); assert(shown['Add slot'] and not shown['##name'])
    frame(nil,nil,'Future capture##slot'); frame('Edit selected'); frame()
    assert(shown['Save changes'])
    frame('Cancel',{['##name']='Discarded edit'}); frame()
    f=assert(io.open(root..'/session.rpp.jg-scheduler','rb')); saved=assert(C.deserialize(f:read('*a'))); f:close()
    eq(saved.slots[2].name,'Future capture')
  end)
  H.new=old
  for _,f in ipairs(exits) do f() end
  assert(ok,err); eq(windows,0); eq(disabled,0); eq(tables,0); eq(ids,0)
  files[root..'/session.rpp.jg-scheduler']=true
end)
for path in pairs(files) do os.remove(path) end
for path in pairs(dirs) do os.remove(path) end
os.remove(root)
print(tests..' host integration tests passed.')
