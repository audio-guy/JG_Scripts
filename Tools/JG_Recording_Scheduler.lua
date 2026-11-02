-- @description Recording Scheduler
-- @author Julius Gass
-- @version 2.1.0
-- @changelog
--   Streamlined Schedule, Setup and Activity views with an on-demand slot editor.
--   Project-bound scheduling, persistent plans, explicit activation and verified results.
--   Strict time validation, pre/post-roll, repeat/duplicate/templates and activity export.
--   Dedicated slot folders named YYMMDD - HHMM Name; continuous live recording mode.
-- @about
--   For unattended audio recordings and attended live capture. Requires ReaImGui 0.10+.
--   Save the project first. Prepare audio inputs, normal record mode, no record length
--   limit, and automatic retention of recorded files. Keep REAPER running and prevent sleep.
--   Separate mode uses a stop/start between slots; continuous mode keeps adjacent slots
--   in the first slot's folder. Timing is wall-clock/defer based, not sample accurate.
--   Plans are stored in project extstate and a recovery sidecar next to the saved project.

local Core = {}
local function copy(t) local r = {}; for k,v in pairs(t) do r[k]=v end; return r end
local function trim(s) return (s or ''):match('^%s*(.-)%s*$') end
local function stamp(t) return t and os.date('%y%m%d - %H%M', t) or '' end
local function encode(s) return tostring(s or ''):gsub('[%%\t\r\n]', function(c) return string.format('%%%02X',c:byte()) end) end
local function decode(s) return (s:gsub('%%(%x%x)', function(c) return string.char(tonumber(c,16)) end)) end
local function fields(line) local r={}; for s in (line..'\t'):gmatch('(.-)\t') do r[#r+1]=decode(s) end; return r end
local function row(...) local t={...}; for i=1,#t do t[i]=encode(t[i]) end; return table.concat(t,'\t') end
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<1e12 end

-- Reject invalid dates and both nonexistent and ambiguous daylight-saving times.
function Core.datetime(date, time)
  local y,m,d = date:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
  if not y then y,m,d=date:match('^(%d%d)(%d%d)(%d%d)$'); if y then y=2000+tonumber(y) end end
  local h,n=time:match('^(%d%d):(%d%d)$')
  if not h then h,n=time:match('^(%d%d)(%d%d)$') end
  y,m,d,h,n=tonumber(y),tonumber(m),tonumber(d),tonumber(h),tonumber(n)
  if not y or not h or y<2000 or y>2099 or m<1 or m>12 or d<1 or d>31 or h>23 or n>59 then
    return nil,'Enter a valid date (YYMMDD) and time (HH:MM or HHMM).'
  end
  local matches={}
  for _,dst in ipairs({false,true}) do
    local ok,t=pcall(os.time,{year=y,month=m,day=d,hour=h,min=n,sec=0,isdst=dst})
    if ok and t then
      local v=os.date('*t',t)
      if v.year==y and v.month==m and v.day==d and v.hour==h and v.min==n then matches[t]=true end
    end
  end
  local result,count=nil,0; for t in pairs(matches) do result=t; count=count+1 end
  if count==0 then return nil,'This date/time does not exist. Check the calendar and daylight-saving change.' end
  if count>1 then return nil,'This time occurs twice during the daylight-saving change. Choose an unambiguous time.' end
  return result
end

function Core.folder(slot)
  local name=slot.name:gsub('[%z\1-\31<>:"/\\|?*]', '_'):gsub('[%. ]+$','')
  if name=='' then name='Recording' end
  -- Preserve UTF-8; limit the derived filename only, never the user's slot name.
  if #name>160 then name=name:sub(1,160):gsub('[\194-\244][\128-\191]*$','') end
  return stamp(slot.start)..' '..name
end
function Core.bounds(s) return s.start-s.pre, s.finish and s.finish+s.post end
function Core.make(form)
  if trim(form.name)=='' then return nil,'Enter a slot name.' end
  local start,err=Core.datetime(form.date,form.start); if not start then return nil,err end
  local finish
  if not form.open then
    local enddate=trim(form.enddate or '')
    if enddate=='' then enddate=form.date end
    finish,err=Core.datetime(enddate,form.finish or '')
    if not finish then return nil,'End: '..err end
    if finish<=start then return nil,'End must be after start. For overnight recordings, enter the next date.' end
  end
  local pre,post=tonumber(form.pre or '0'),tonumber(form.post or '0')
  if not finite(pre) or not finite(post) or pre<0 or post<0 or pre>3600 or post>3600 or pre%1~=0 or post%1~=0 then
    return nil,'Pre-roll and post-roll must be whole seconds from 0 to 3600.'
  end
  return {id=0,name=form.name,start=start,finish=finish,pre=pre,post=post,status='Scheduled',note='',actual_start=nil,actual_end=nil,folder=''}
end
function Core.conflict(slots)
  local pending={}
  for _,s in ipairs(slots) do if s.status=='Scheduled' then pending[#pending+1]=s end end
  table.sort(pending,function(a,b) return a.start-a.pre < b.start-b.pre end)
  for i=2,#pending do
    local _,lastend=Core.bounds(pending[i-1]); local start=Core.bounds(pending[i])
    if not lastend or start<lastend then return pending[i-1],pending[i] end
  end
end
function Core.repeat_slots(s, count, days)
  if not count or count%1~=0 or count<1 or count>100 then return nil,'Repeat count must be 1 to 100.' end
  if days~=1 and days~=7 then return nil,'Repeat interval must be daily or weekly.' end
  if count>1 and not s.finish then return nil,'Repeating slots need an end time.' end
  local result={}
  for i=0,count-1 do
    local n=copy(s)
    for _,key in ipairs({'start','finish'}) do
      if s[key] then
        local t=os.date('*t',s[key]); local normalized=os.time{year=t.year,month=t.month,day=t.day+i*days,hour=12}
        local value,err=Core.datetime(os.date('%y%m%d',normalized),os.date('%H:%M',s[key]))
        if not value then return nil,err end
        n[key]=value
      end
    end
    result[#result+1]=n
  end
  return result
end
function Core.new()
  return {slots={},log={},templates={},next_id=1,enabled=false,mode='separate',root='',revision=0}
end
function Core.add_log(state,now,message)
  state.log[#state.log+1]={time=now,message=message}; state.revision=state.revision+1
end
function Core.apply(state, additions, replace_id)
  local nextslots={}
  for _,s in ipairs(state.slots) do
    if s.id~=replace_id then nextslots[#nextslots+1]=s
    elseif s.status~='Scheduled' then return nil,'Only scheduled slots can be edited.' end
  end
  for _,s in ipairs(additions) do nextslots[#nextslots+1]=copy(s) end
  local a,b=Core.conflict(nextslots)
  if a then return nil,'Overlap (including pre/post-roll): '..a.name..' / '..b.name..'. Adjust the times before saving.' end
  local nextid=state.next_id
  for i=#nextslots-#additions+1,#nextslots do
    nextslots[i].id=nextid; nextid=nextid+1
  end
  table.sort(nextslots,function(x,y) return x.start<y.start end)
  state.slots=nextslots; state.next_id=nextid; state.revision=state.revision+1
  return true
end

-- A versioned, escaped data format; never execute stored project data as Lua.
function Core.serialize(st)
  local out={row('JG_RECORDING_SCHEDULER',2),row('P',st.mode,st.root,st.next_id,st.revision)}
  for _,s in ipairs(st.slots) do out[#out+1]=row('S',s.id,s.name,s.start,s.finish or '',s.pre,s.post,s.status,s.note,s.actual_start or '',s.actual_end or '',s.folder or '') end
  for _,e in ipairs(st.log) do out[#out+1]=row('L',e.time,e.message) end
  for _,t in ipairs(st.templates) do out[#out+1]=row('T',t.name,t.start,t.finish,t.open and '1' or '0',t.pre,t.post,t.enddays or 0) end
  return table.concat(out,'\n')..'\n'
end
function Core.deserialize(text)
  if not text or text=='' then return Core.new() end
  local st=Core.new(); local first=true; local ids={}
  local statuses={Scheduled=true,Recording=true,Starting=true,Completed=true,Partial=true,Stopped=true,Missed=true,Failed=true,Interrupted=true}
  for line in text:gmatch('[^\n]+') do
    local f=fields(line)
    if first then
      if f[1]~='JG_RECORDING_SCHEDULER' or f[2]~='2' then return nil,'Unsupported or damaged schedule data.' end
      first=false
    elseif f[1]=='P' then
      if f[2]~='separate' and f[2]~='continuous' then return nil,'Invalid recording mode in saved plan.' end
      st.mode,st.root,st.next_id,st.revision=f[2],f[3],tonumber(f[4]),tonumber(f[5])
      if not finite(st.next_id) or st.next_id<1 or not finite(st.revision) then return nil,'Invalid plan metadata.' end
    elseif f[1]=='S' then
      local s={id=tonumber(f[2]),name=f[3],start=tonumber(f[4]),finish=tonumber(f[5]),pre=tonumber(f[6]),post=tonumber(f[7]),status=f[8],note=f[9],actual_start=tonumber(f[10]),actual_end=tonumber(f[11]),folder=f[12]}
      if #f~=12 or not finite(s.id) or s.id%1~=0 or ids[s.id] or not finite(s.start) or not finite(s.pre) or not finite(s.post) or s.pre<0 or s.post<0 or s.pre>3600 or s.post>3600 or not statuses[s.status] or (f[5]~='' and (not finite(s.finish) or s.finish<=s.start)) then return nil,'Invalid slot in saved plan.' end
      ids[s.id]=true; st.next_id=math.max(st.next_id,s.id+1)
      st.slots[#st.slots+1]=s
    elseif f[1]=='L' and tonumber(f[2]) then st.log[#st.log+1]={time=tonumber(f[2]),message=f[3]}
    elseif f[1]=='T' and #f==8 then
      st.templates[#st.templates+1]={name=f[2],start=f[3],finish=f[4],open=f[5]=='1',pre=f[6],post=f[7],enddays=tonumber(f[8]) or 0}
    else return nil,'Damaged schedule data.' end
  end
  if first or Core.conflict(st.slots) then return nil,'Empty or overlapping saved plan.' end
  for _,s in ipairs(st.slots) do
    if s.status=='Recording' or s.status=='Starting' then s.status='Interrupted'; s.note='Previous scheduler session ended. Inspect the audio files before continuing.' end
  end
  return st
end

-- State machine: called on every defer cycle, independently of window visibility.
local Engine={}; Engine.__index=Engine
function Engine.new(state,host) return setmetatable({state=state,host=host,active=nil,session={},last_wall=nil,last_mono=nil},Engine) end
function Engine:log(now,text) Core.add_log(self.state,now,text) end
function Engine:disable(now,why) self.state.enabled=false; self:log(now,why or 'Schedule disabled. Active recording keeps its planned end.') end
function Engine:enable(now)
  local ok,err=self.host:preflight(true); if not ok then return nil,err end
  if self.active then return nil,'Finish the current recording before enabling a new plan.' end
  local future=false
  for _,s in ipairs(self.state.slots) do if s.status=='Scheduled' then
    local begin=Core.bounds(s)
    if begin<=now then return nil,'A scheduled start is already in the past. Edit or remove that slot before enabling.' end
    future=true
  end end
  if not future then return nil,'Add a future slot before enabling the schedule.' end
  if self.host.prepare then
    local prepared,problem=self.host:prepare(self.state)
    if not prepared then return nil,problem end
  end
  self.state.enabled=true; self:log(now,'Schedule enabled.'); return true
end
function Engine:finalize(now,requested,reason)
  local ok,detail=self.host:verify()
  for _,s in ipairs(self.session) do
    s.actual_end=s.actual_end or now
    if not ok then s.status='Failed'; s.note=detail
    elseif s==self.active and requested~='Completed' then s.status=requested; s.note=reason
    elseif s.note~='' then s.status='Partial'
    else s.status='Completed'; s.note='Recorded files found on every expected track. Audio content not checked.' end
    self:log(now,Core.folder(s)..': '..s.status..'. '..(s.note or ''))
  end
  for _,path in ipairs(self.host.result_files or {}) do self:log(now,'Recorded file: '..path) end
  self.host:restore(); self.session={}; self.active=nil
end
function Engine:stop(now,reason)
  self.state.enabled=false
  if self.active then
    self.host:stop()
    if self.host:recording() then self:log(now,'Stop failed. Recording is still active; use REAPER transport.'); return nil end
    self:finalize(now,'Stopped',reason or 'Stopped by user.')
  end
  return true
end
function Engine:extend(now,seconds)
  if not self.active or not self.active.finish then return nil,'This recording has no scheduled end.' end
  local proposed=copy(self.active); proposed.finish=proposed.finish+seconds; proposed.status='Scheduled'
  local check={proposed}
  for _,s in ipairs(self.state.slots) do if s.status=='Scheduled' then check[#check+1]=s end end
  if Core.conflict(check) then return nil,'Extension overlaps a later slot (including pre/post-roll).' end
  self.active.finish=proposed.finish
  self:log(now,'Recording extended to '..stamp(proposed.finish)..'.')
  return true
end
function Engine:tick(now,mono)
  if not self.host:valid() then
    if self.active then self.active.status='Interrupted'; self.active.note='Target project closed.'; self:log(now,self.active.note) end
    self.state.enabled=false; return false
  end
  if self.last_wall and math.abs((now-self.last_wall)-(mono-self.last_mono))>3 then
    self:disable(now,'System clock changed. Check the schedule before enabling again.')
    if self.active then self.active.note='System clock changed during recording; review timing.' end
  end
  self.last_wall,self.last_mono=now,mono
  if self.state.enabled and not self.host:selected() then self:disable(now,'Target project is no longer selected. Future starts disabled; active recording keeps its end.') end
  if self.active then
    local s=self.active
    if self.host.paused and self.host:paused() then
      self:stop(now,'Recording was paused. Inspect the recorded duration.'); return true
    end
    if not self.host:recording() then
      self:disable(now,'Recording stopped outside the scheduler.')
      self:finalize(now,'Stopped','Recording stopped before the scheduled end.'); return true
    end
    local _,ending=Core.bounds(s)
    if ending and now>=ending then
      local nextslot
      if self.state.enabled and self.state.mode=='continuous' then
        for _,n in ipairs(self.state.slots) do if n.status=='Scheduled' and Core.bounds(n)==ending then nextslot=n; break end end
      end
      if nextslot and (not nextslot.finish or now<nextslot.finish+nextslot.post) then
        s.actual_end=now; s.status='Recording'; s.note=s.note or ''
        nextslot.status='Recording'; nextslot.actual_start=now; nextslot.folder=s.folder
        if now-ending>2 then nextslot.note='Slot boundary processed late; continuous audio retained.' end
        self.session[#self.session+1]=nextslot; self.active=nextslot
        self.host:marker(nextslot); self:log(now,Core.folder(nextslot)..': continuous boundary; files remain in '..s.folder)
      else
        self.host:stop()
        if self.host:recording() then
          if not self.stop_warning then self:disable(now,'Automatic stop failed. Use REAPER transport.'); self.stop_warning=true end
          return true
        end
        if now-ending>2 then s.note='Automatic stop was late by '..(now-ending)..' seconds.' end
        self:finalize(now,'Completed','')
      end
    end
  end
  if self.state.enabled and not self.active then
    for _,s in ipairs(self.state.slots) do if s.status=='Scheduled' then
      local begin,ending=Core.bounds(s)
      if ending and now>=ending then
        s.status='Missed'; s.note='Entire recording window elapsed.'; self:log(now,Core.folder(s)..': Missed.')
      elseif now>=begin then
        -- Never silently start substantially late after a stalled UI or sleep.
        if now-begin>5 then
          s.status='Missed'; s.note='Start missed by more than 5 seconds. Duplicate/edit to reschedule.'; self:log(now,Core.folder(s)..': '..s.note)
        else
          local ok,err=self.host:preflight(false)
          if ok then ok,err=self.host:start(s,self.state.root) end
          if not ok or not self.host:recording() then
            s.status='Failed'; s.note=err or 'REAPER did not enter recording.'
            self.host:restore(); self:disable(now,Core.folder(s)..': '..s.note)
          else
            s.status='Recording'; s.actual_start=now
            if now-begin>2 then s.note='Recording started '..(now-begin)..' seconds late.' end
            self.active=s; self.session={s}; self.host:marker(s)
            self:log(now,Core.folder(s)..': Recording to '..s.folder)
          end
        end
        break
      end
    end end
  end
  if self.state.enabled and not self.active then
    local pending=false
    for _,s in ipairs(self.state.slots) do if s.status=='Scheduled' then pending=true; break end end
    if not pending then self:disable(now,'Schedule finished. Review slot results and the activity log.') end
  end
  return true
end

local Host={}; Host.__index=Host
function Host.new(api,project) return setmetatable({r=api,project=project,baseline={},expected={},saved=nil,confirmed=false},Host) end
function Host:valid() return self.r.ValidatePtr(self.project,'ReaProject*') end
function Host:selected() return self.r.EnumProjects(-1,'')==self.project end
function Host:project_file()
  local i=0; while true do local p,path=self.r.EnumProjects(i,''); if not p then return '' end; if p==self.project then return path end; i=i+1 end
end
function Host:recording() return (self.r.GetPlayStateEx(self.project)&4)~=0 end
function Host:paused() return (self.r.GetPlayStateEx(self.project)&2)~=0 end
function Host:tracks()
  local tracks={}
  for i=0,self.r.CountTracks(self.project)-1 do
    local t=self.r.GetTrack(self.project,i)
    if self.r.GetMediaTrackInfo_Value(t,'I_RECARM')==1 then tracks[#tracks+1]=t end
  end
  return tracks
end
function Host:preflight(enabling)
  local r=self.r
  if not self:valid() then return nil,'The target project has been closed.' end
  if not self:selected() then return nil,'Select the target project before starting the schedule.' end
  if self:project_file()=='' then return nil,'Save the REAPER project before scheduling.' end
  if r.GetPlayStateEx(self.project)~=0 then return nil,'Stop the transport first. Existing recordings are never taken over.' end
  local tracks=self:tracks()
  if #tracks==0 then return nil,'Arm at least one audio track.' end
  for _,t in ipairs(tracks) do
    local input=r.GetMediaTrackInfo_Value(t,'I_RECINPUT')
    if input<0 or input>=4096 or r.GetMediaTrackInfo_Value(t,'I_RECMODE')~=0 then return nil,'Armed tracks must use audio inputs and Record: input (audio or MIDI).' end
  end
  local device=r.GetAudioDeviceInfo('SRATE')
  if not device then return nil,'The audio device is not open.' end
  if r.GetSetRepeatEx(self.project,-1)~=0 then return nil,'Disable loop/repeat before enabling the schedule.' end
  if not self.confirmed then return nil,'Complete the recording setup confirmation below.' end
  if self.storage_error then return nil,self.storage_error end
  return true
end
local function join(a,b) return a:gsub('[/\\]+$','')..'/'..b end
local function absolute(s) return s:match('^[/\\]') or s:match('^%a:[/\\]') end
function Host:root_path(root)
  if root=='' then return self.r.GetProjectPathEx(self.project,'') end
  if absolute(root) then return root end
  return join(self:project_file():match('^(.*)[/\\]') or '',root)
end
function Host:writable(path)
  self.r.RecursiveCreateDirectory(path,0)
  local probe=join(path,'.jg-write-check-'..self.r.genGuid():gsub('[^%w]',''))
  local f,err=io.open(probe,'wb'); if not f then return nil,'Cannot write to recording folder: '..tostring(err) end
  local ok=f:write('check'); local closed=f:close(); os.remove(probe)
  if not ok or not closed then return nil,'Recording folder write check failed.' end
  return true
end
function Host:prepare(state)
  -- Exercise every destination before arming; repeat the check at the actual start.
  for _,s in ipairs(state.slots) do
    if s.status=='Scheduled' then
      local ok,err=self:writable(join(self:root_path(state.root),Core.folder(s)))
      if not ok then return nil,err end
    end
  end
  return true
end
function Host:source_map()
  local files,lengths={},{}
  for _,track in ipairs(self.expected) do
    if self.r.ValidatePtr2(self.project,track,'MediaTrack*') then
      for i=0,self.r.CountTrackMediaItems(track)-1 do
        local item=self.r.GetTrackMediaItem(track,i)
        for j=0,self.r.CountTakes(item)-1 do
          local take=self.r.GetTake(item,j)
          if take and not self.r.TakeIsMIDI(take) then
            local src=self.r.GetMediaItemTake_Source(take)
            local path=self.r.GetMediaSourceFileName(src,'')
            if path~='' then files[path]=track; lengths[path]=self.r.GetMediaSourceLength(src) end
          end
        end
      end
    end
  end
  return files,lengths
end
function Host:start(slot,root)
  local r=self.r
  local path=join(self:root_path(root),Core.folder(slot))
  local ok,err=self:writable(path); if not ok then return nil,err end
  local _,oldpath=r.GetSetProjectInfo_String(self.project,'RECORD_PATH','',false)
  local _,tag=r.GetSetProjectInfo_String(self.project,'RECTAG','',false)
  self.saved={path=oldpath,tag=tag,newpath=path,newtag=Core.folder(slot)}
  self.expected=self:tracks(); self.baseline=self:source_map()
  local changed=r.GetSetProjectInfo_String(self.project,'RECORD_PATH',path,true)
  if not changed then self:restore(); return nil,'REAPER rejected the recording folder.' end
  r.GetSetProjectInfo_String(self.project,'RECTAG',self.saved.newtag,true)
  -- Append after existing content. Never seek to a wall-clock position over user media.
  local position=math.max(r.GetCursorPositionEx(self.project),r.GetProjectLength(self.project))
  r.SetEditCurPos2(self.project,position,false,false)
  self.owns_transport=true
  r.Main_OnCommandEx(1013,0,self.project)
  if not self:recording() then self:restore(); return nil,'REAPER did not start recording. Check the audio device and recording settings.' end
  slot.folder=path
  return true
end
function Host:marker(slot)
  self.r.AddProjectMarker2(self.project,false,self.r.GetPlayPositionEx(self.project),0,Core.folder(slot),-1,0)
end
function Host:stop() if self:valid() and self:recording() then self.r.OnStopButtonEx(self.project) end end
function Host:verify()
  local seen={}; local paths={}
  local sources,lengths=self:source_map()
  for path,track in pairs(sources) do
    local destination=self.saved and self.saved.newpath
    if not self.baseline[path] and destination and path:sub(1,#destination+1)==destination..'/' then
      local f=io.open(path,'rb')
      if f then local size=f:seek('end'); f:close(); if size and size>0 and (lengths[path] or 0)>0 then seen[track]=true; paths[#paths+1]=path end end
    end
  end
  self.result_files=paths
  for _,t in ipairs(self.expected) do if not seen[t] then return nil,'Recorded files could not be confirmed on every expected track. Inspect the project and disk.' end end
  if #self.expected==0 then return nil,'No recorded tracks could be verified.' end
  return true
end
function Host:restore()
  if self.saved and self:valid() then
    for _,pair in ipairs({{'RECORD_PATH','path','newpath'},{'RECTAG','tag','newtag'}}) do
      local _,current=self.r.GetSetProjectInfo_String(self.project,pair[1],'',false)
      -- Do not overwrite a deliberate external change made during recording.
      if current==self.saved[pair[3]] then self.r.GetSetProjectInfo_String(self.project,pair[1],self.saved[pair[2]],true) end
    end
  end
  self.saved=nil
  if not self:recording() then self.owns_transport=false end
end

local function run(r)
  if not r.ImGui_CreateContext then r.ShowMessageBox('Install ReaImGui via ReaPack, then run Recording Scheduler again.','Recording Scheduler',0); return end
  local project=r.EnumProjects(-1,''); local host=Host.new(r,project)
  local section='JG_Recording_Scheduler_v2'
  local lockkey=tostring(project)
  if r.GetExtState(section,lockkey)~='' then r.ShowMessageBox('A scheduler is already open for this project. Close that window first.','Recording Scheduler',0); return end
  local token=r.genGuid(); r.SetExtState(section,lockkey,token,false)
  local exit_handler=function() if r.GetExtState(section,lockkey)==token then r.DeleteExtState(section,lockkey,false) end end
  r.atexit(function() exit_handler() end)
  local _,stored=r.GetProjExtState(project,section,'plan')
  local state,loaderr=Core.deserialize(stored)
  local sidecar=host:project_file()~='' and host:project_file()..'.jg-scheduler' or nil
  if sidecar then
    local f=io.open(sidecar,'rb')
    if f then local data=f:read('*a'); f:close(); local recovery,err=Core.deserialize(data)
      if recovery and (not state or recovery.revision>state.revision) then state=recovery
      elseif not recovery then loaderr=err end
    end
  end
  state=state or Core.new()
  local engine=Engine.new(state,host)
  local ctx=r.ImGui_CreateContext('Recording Scheduler',r.ImGui_ConfigFlags_NavEnableKeyboard())
  local form={date=os.date('%y%m%d'),start='',enddate=os.date('%y%m%d'),finish='',name='',open=false,pre='0',post='0'}
  local editing=nil; local error=loaderr or ''; local count='1'; local weekly=false; local template_index=1
  local close_requested=false; local show_history=false; local last_saved=-1; local last_check=0; local readiness=''; local ready=false
  local undo=nil
  local function save()
    if not host:valid() then return end
    if loaderr then return end -- Preserve damaged data for recovery; never replace it with an empty plan.
    if state.revision==last_saved and sidecar==(host:project_file()..'.jg-scheduler') then return end
    local data=Core.serialize(state)
    r.SetProjExtState(project,section,'plan',data)
    local file=host:project_file()
    if file~='' then
      local destination=file..'.jg-scheduler'; local temp=destination..'.tmp'
      local f,err=io.open(temp,'wb')
      local ok=false
      if f then ok=f:write(data)~=nil; ok=f:close() and ok end
      if ok then ok,err=os.rename(temp,destination) end
      if not ok then host.storage_error='Cannot save recovery plan: '..tostring(err); error=host.storage_error; state.enabled=false; os.remove(temp); return end
    end
    host.storage_error=nil; last_saved=state.revision
    sidecar=file~='' and file..'.jg-scheduler' or nil
  end
  local function snapshot() undo=Core.serialize(state) end
  local function clear_form() editing=nil; form.start=''; form.finish=''; form.name=''; count='1'; error='' end
  local function editable() return not state.enabled and not engine.active end
  local function text(s) r.ImGui_TextWrapped(ctx,tostring(s)) end
  local function edit(s,duplicate)
    editing=not duplicate and s.id or nil
    form={date=os.date('%y%m%d',s.start),start=os.date('%H:%M',s.start),enddate=os.date('%y%m%d',s.finish or s.start),finish=s.finish and os.date('%H:%M',s.finish) or '',name=s.name,open=not s.finish,pre=tostring(s.pre),post=tostring(s.post)}
    count='1'; error=duplicate and 'Choose a new date/time for this duplicate.' or ''
  end
  local function export()
    local file=host:project_file(); if file=='' then error='Save the project first.'; return end
    local path=file..'.recording-log.tsv'; local f,err=io.open(path,'wb')
    if not f then error='Cannot export activity log: '..tostring(err); return end
    local out={row('Recording Scheduler activity log'),row('Project',file),row('Slot','Planned start','Planned end','Actual start','Actual end','Status','Folder','Details')}
    for _,s in ipairs(state.slots) do out[#out+1]=row(s.name,stamp(s.start),stamp(s.finish),stamp(s.actual_start),stamp(s.actual_end),s.status,s.folder,s.note) end
    out[#out+1]=row('Time','Event')
    for _,e in ipairs(state.log) do out[#out+1]=row(os.date('%y%m%d - %H%M%S',e.time),e.message) end
    local ok=f:write(table.concat(out,'\n')..'\n'); local closed=f:close()
    error=ok and closed and ('Log exported: '..path) or 'Could not finish writing the activity log.'
  end
  local view='Schedule'
  local editor_open=false
  local selected_id=nil
  local setup_checks={false,false,false,false}
  local function duration(seconds)
    seconds=math.max(0,math.floor(seconds))
    return string.format('%02d:%02d:%02d',seconds//3600,(seconds%3600)//60,seconds%60)
  end
  local function muted(message) r.ImGui_TextColored(ctx,0xAEB6C2FF,tostring(message)) end
  local function status(label)
    local colors={Recording=0xFF8585FF,Enabled=0x93D9B3FF,Completed=0x93D9B3FF,Ready=0x93D9B3FF,
      Failed=0xFF8585FF,Missed=0xF1C777FF,Partial=0xF1C777FF,Interrupted=0xF1C777FF}
    r.ImGui_TextColored(ctx,colors[label] or 0xD5DBE3FF,label)
  end
  local function field(label,key)
    text(label)
    r.ImGui_SetNextItemWidth(ctx,-1)
    local changed,value=r.ImGui_InputText(ctx,'##'..key,form[key])
    if changed then
      -- Keep same-day dates in sync until the user deliberately chooses another end date.
      if key=='date' and form.enddate==form.date then form.enddate=value end
      form[key]=value
    end
  end
  local function start_editor(s,duplicate)
    error=''
    if s then edit(s,duplicate) else clear_form(); form.date=os.date('%y%m%d'); form.enddate=form.date end
    editor_open=true
  end
  local function commit_form(now)
    local s,err=Core.make(form)
    if s then
      local additions; additions,err=Core.repeat_slots(s,editing and 1 or tonumber(count),weekly and 7 or 1)
      if additions then
        if Core.bounds(additions[1])<=now then err='Start including pre-roll must be in the future.'
        else
          snapshot()
          local ok; ok,err=Core.apply(state,additions,editing)
          if ok then selected_id=state.next_id-#additions; clear_form(); editor_open=false end
        end
      end
    end
    error=err or ''
  end
  local function draw_editor(now)
    text(editing and 'Edit slot' or 'New slot')
    field('Name','name')
    if r.ImGui_BeginTable(ctx,'Slot times',2,r.ImGui_TableFlags_SizingStretchSame()) then
      r.ImGui_TableNextRow(ctx)
      r.ImGui_TableNextColumn(ctx); field('Start date  /  YYMMDD','date')
      r.ImGui_TableNextColumn(ctx); field('Start time  /  HH:MM','start')
      r.ImGui_TableNextRow(ctx)
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_BeginDisabled(ctx,form.open); field('End date  /  YYMMDD','enddate'); r.ImGui_EndDisabled(ctx)
      r.ImGui_TableNextColumn(ctx)
      r.ImGui_BeginDisabled(ctx,form.open); field('End time  /  HH:MM','finish'); r.ImGui_EndDisabled(ctx)
      r.ImGui_EndTable(ctx)
    end
    local changed,value=r.ImGui_Checkbox(ctx,'Open-ended recording (manual stop)',form.open)
    if changed then form.open=value end
    if r.ImGui_CollapsingHeader(ctx,'Pre-roll, post-roll and repetition') then
      if r.ImGui_BeginTable(ctx,'Slot options',2,r.ImGui_TableFlags_SizingStretchSame()) then
        r.ImGui_TableNextRow(ctx)
        r.ImGui_TableNextColumn(ctx); field('Pre-roll  /  seconds','pre')
        r.ImGui_TableNextColumn(ctx); field('Post-roll  /  seconds','post')
        r.ImGui_EndTable(ctx)
      end
      if not editing then
        r.ImGui_SetNextItemWidth(ctx,120)
        changed,value=r.ImGui_InputText(ctx,'Occurrences (1-100)',count); if changed then count=value end
        changed,value=r.ImGui_Checkbox(ctx,'Repeat weekly instead of daily',weekly); if changed then weekly=value end
      end
    end
    if r.ImGui_CollapsingHeader(ctx,'Templates') then
      if #state.templates>0 then
        local names={}; for _,t in ipairs(state.templates) do names[#names+1]=t.name end
        local choice
        changed,choice=r.ImGui_Combo(ctx,'Saved template',template_index-1,table.concat(names,'\0')..'\0')
        if changed then template_index=choice+1 end
        if r.ImGui_Button(ctx,'Apply template') then
          local t=state.templates[template_index] or state.templates[1]
          for _,key in ipairs({'name','start','finish','open','pre','post'}) do form[key]=t[key] end
          local date=Core.datetime(form.date,'12:00')
          if date then
            local d=os.date('*t',date)
            form.enddate=os.date('%y%m%d',os.time{year=d.year,month=d.month,day=d.day+t.enddays,hour=12})
          end
        end
      else muted('No templates saved in this project.') end
      if r.ImGui_Button(ctx,'Save form as template') then
        local s,err=Core.make(form)
        if not s then error=err else
          snapshot()
          local a=os.date('*t',s.start); local b=os.date('*t',s.finish or s.start)
          local days=math.floor((os.time{year=b.year,month=b.month,day=b.day,hour=12}-os.time{year=a.year,month=a.month,day=a.day,hour=12})/86400+0.5)
          local template=copy(form); template.enddays=days
          state.templates[#state.templates+1]=template; state.revision=state.revision+1; error='Template saved.'
        end
      end
    end
    local preview=Core.make(form)
    r.ImGui_Separator(ctx)
    if preview then
      local begin,ending=Core.bounds(preview)
      text('Folder: '..Core.folder(preview))
      muted(ending and ('Recording length: '..duration(ending-begin)) or 'Recording ends manually.')
      if preview.pre>0 or preview.post>0 then text('Including margins: '..stamp(begin)..' to '..(ending and stamp(ending) or 'manual stop')) end
    else muted('Enter a name and valid times to preview the recording folder.') end
    if error~='' then text(error) end
    if r.ImGui_Button(ctx,editing and 'Save changes' or 'Add slot',140,0) then commit_form(now) end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx,'Cancel',90,0) then clear_form(); editor_open=false end
  end
  local function draw_setup()
    text('Recording destination')
    r.ImGui_BeginDisabled(ctx,not editable())
    r.ImGui_SetNextItemWidth(ctx,-1)
    local changed,value=r.ImGui_InputText(ctx,'##recording_root',state.root)
    if changed then state.root=value; state.revision=state.revision+1 end
    muted('Leave blank to use the project recording path.')
    text(host:root_path(state.root))
    r.ImGui_Separator(ctx)
    text('Between slots')
    local mode=state.mode=='continuous' and 1 or 0
    r.ImGui_SetNextItemWidth(ctx,-1)
    changed,value=r.ImGui_Combo(ctx,'##recording_mode',mode,'Separate recordings / one folder per slot\0Continuous live recording / shared folder\0')
    if changed then state.mode=value==1 and 'continuous' or 'separate'; state.revision=state.revision+1 end
    text(state.mode=='continuous'
      and 'Adjacent slots stay in one uninterrupted recording. All files remain in the first slot folder; each slot adds a marker.'
      or 'Each slot gets its own folder. Stop/start between slots can leave an audio gap.')
    r.ImGui_Separator(ctx)
    text('Before enabling')
    local labels={
      'Normal record mode; no recording limit or count-in',
      'Recorded files are kept without a confirmation dialog',
      'Inputs, levels and available disk space checked',
      'Computer stays awake; REAPER remains running',
    }
    for i,label in ipairs(labels) do
      changed,value=r.ImGui_Checkbox(ctx,label,setup_checks[i])
      if changed then
        setup_checks[i]=value; host.confirmed=true
        for _,checked in ipairs(setup_checks) do host.confirmed=host.confirmed and checked end
        last_check=0
      end
    end
    muted('These checks are confirmed by you, not measured by the scheduler.')
    r.ImGui_EndDisabled(ctx)
    if not editable() then text('Disable future starts and finish the active recording to change setup.') end
    if r.ImGui_CollapsingHeader(ctx,'Timing and recovery') then
      text('Keep REAPER running. Scheduling follows the system clock and is not sample accurate. A late start may be missed.')
      text('Plans are saved with this project and in a recovery sidecar. After reopening, explicitly enable the schedule again.')
      text('Completed means new files were found on every expected track. Check the audio before treating a recording as verified.')
    end
  end
  local function draw_schedule(now)
    if editor_open and editable() then draw_editor(now); return end
    r.ImGui_BeginDisabled(ctx,not editable())
    if r.ImGui_Button(ctx,'Add slot',110,0) then start_editor() end
    r.ImGui_SameLine(ctx)
    r.ImGui_BeginDisabled(ctx,not undo)
    if r.ImGui_Button(ctx,'Undo') then
      local old=Core.deserialize(undo)
      if old then
        local revision=state.revision
        state.slots=old.slots; state.next_id=old.next_id; state.templates=old.templates
        state.revision=revision+1; undo=nil; selected_id=nil; clear_form()
      end
    end
    r.ImGui_EndDisabled(ctx); r.ImGui_EndDisabled(ctx)
    r.ImGui_SameLine(ctx)
    local changed,value=r.ImGui_Checkbox(ctx,'Show history',show_history); if changed then show_history=value end
    local _,height=r.ImGui_GetContentRegionAvail(ctx)
    local tableheight=math.max(150,height-155)
    local flags=r.ImGui_TableFlags_RowBg()|r.ImGui_TableFlags_Resizable()|r.ImGui_TableFlags_ScrollY()
    if r.ImGui_BeginTable(ctx,'Schedule v2.1',6,flags,0,tableheight) then
      r.ImGui_TableSetupColumn(ctx,'Name',r.ImGui_TableColumnFlags_WidthStretch())
      for _,column in ipairs({{'Date',78},{'Start',64},{'End',64},{'Length',84},{'Status',110}}) do
        r.ImGui_TableSetupColumn(ctx,column[1],r.ImGui_TableColumnFlags_WidthFixed(),column[2])
      end
      r.ImGui_TableSetupScrollFreeze(ctx,0,1); r.ImGui_TableHeadersRow(ctx)
      local visible_count=0
      for _,s in ipairs(state.slots) do
        -- Failures remain visible even when successful history is hidden.
        local hidden=s.status=='Completed' or s.status=='Stopped'
        if show_history or not hidden then
          visible_count=visible_count+1
          r.ImGui_PushID(ctx,s.id); r.ImGui_TableNextRow(ctx,0,34)
          r.ImGui_TableNextColumn(ctx)
          if r.ImGui_Selectable(ctx,s.name..'##slot',selected_id==s.id,r.ImGui_SelectableFlags_SpanAllColumns()) then selected_id=s.id end
          r.ImGui_TableNextColumn(ctx); r.ImGui_Text(ctx,os.date('%y%m%d',s.start))
          r.ImGui_TableNextColumn(ctx); r.ImGui_Text(ctx,os.date('%H:%M',s.start))
          r.ImGui_TableNextColumn(ctx); r.ImGui_Text(ctx,s.finish and os.date('%H:%M',s.finish) or 'Open')
          r.ImGui_TableNextColumn(ctx); r.ImGui_Text(ctx,s.finish and duration(s.finish-s.start) or '--')
          r.ImGui_TableNextColumn(ctx); status(s.status)
          r.ImGui_PopID(ctx)
        end
      end
      if visible_count==0 then
        r.ImGui_TableNextRow(ctx); r.ImGui_TableNextColumn(ctx)
        text(#state.slots==0 and 'Add your first recording slot.' or 'No upcoming slots. Enable Show history to see past recordings.')
      end
      r.ImGui_EndTable(ctx)
    end
    local selected
    for _,s in ipairs(state.slots) do if s.id==selected_id then selected=s; break end end
    if selected then
      r.ImGui_BeginDisabled(ctx,not editable())
      r.ImGui_BeginDisabled(ctx,selected.status~='Scheduled')
      if r.ImGui_Button(ctx,'Edit selected') then start_editor(selected,false) end
      r.ImGui_EndDisabled(ctx); r.ImGui_SameLine(ctx)
      if r.ImGui_Button(ctx,'Duplicate') then start_editor(selected,true) end
      r.ImGui_SameLine(ctx); r.ImGui_BeginDisabled(ctx,selected.status~='Scheduled')
      if r.ImGui_Button(ctx,'Delete') then
        snapshot()
        for i,s in ipairs(state.slots) do if s.id==selected.id then table.remove(state.slots,i); break end end
        state.revision=state.revision+1; selected_id=nil; clear_form()
      end
      r.ImGui_EndDisabled(ctx); r.ImGui_EndDisabled(ctx)
      if selected.note~='' then text(selected.note) end
      if r.ImGui_CollapsingHeader(ctx,'Selected slot details') then
        text('Folder: '..(selected.folder~='' and selected.folder or Core.folder(selected)))
        local begin,ending=Core.bounds(selected)
        text('Recording window: '..stamp(begin)..' to '..(ending and stamp(ending) or 'manual stop'))
        text('Pre-roll: '..selected.pre..' s  /  Post-roll: '..selected.post..' s')
      end
    else muted('Select a slot to edit, duplicate or inspect its details.') end
    if not editable() then muted('Plan editing is locked while the schedule is enabled or recording.') end
    if error~='' then text(error) end
  end
  local function draw_activity()
    if r.ImGui_Button(ctx,'Export log') then export() end
    r.ImGui_SameLine(ctx); muted('Recorded files and scheduling events')
    if error~='' then text(error) end
    local _,height=r.ImGui_GetContentRegionAvail(ctx)
    if r.ImGui_BeginTable(ctx,'Activity',2,r.ImGui_TableFlags_RowBg()|r.ImGui_TableFlags_ScrollY(),0,math.max(120,height-8)) then
      r.ImGui_TableSetupColumn(ctx,'Time',r.ImGui_TableColumnFlags_WidthFixed(),150)
      r.ImGui_TableSetupColumn(ctx,'Event',r.ImGui_TableColumnFlags_WidthStretch())
      r.ImGui_TableSetupScrollFreeze(ctx,0,1); r.ImGui_TableHeadersRow(ctx)
      for i=#state.log,1,-1 do
        r.ImGui_TableNextRow(ctx); r.ImGui_TableNextColumn(ctx)
        r.ImGui_Text(ctx,os.date('%y%m%d  %H:%M:%S',state.log[i].time))
        r.ImGui_TableNextColumn(ctx); text(state.log[i].message)
      end
      if #state.log==0 then r.ImGui_TableNextRow(ctx); r.ImGui_TableNextColumn(ctx); text('No events yet.') end
      r.ImGui_EndTable(ctx)
    end
  end
  local function draw(now)
    r.ImGui_SetNextWindowSize(ctx,940,640,r.ImGui_Cond_FirstUseEver())
    r.ImGui_SetNextWindowSizeConstraints(ctx,800,540,1600,1400)
    if close_requested then r.ImGui_SetNextWindowCollapsed(ctx,false) end
    r.ImGui_PushStyleVar(ctx,r.ImGui_StyleVar_WindowPadding(),16,14)
    r.ImGui_PushStyleVar(ctx,r.ImGui_StyleVar_FramePadding(),10,6)
    r.ImGui_PushStyleVar(ctx,r.ImGui_StyleVar_ItemSpacing(),10,8)
    r.ImGui_PushStyleVar(ctx,r.ImGui_StyleVar_CellPadding(),8,6)
    r.ImGui_PushStyleVar(ctx,r.ImGui_StyleVar_FrameRounding(),4)
    local visible,open=r.ImGui_Begin(ctx,'Recording Scheduler',true)
    local quit=false
    if visible then
      r.ImGui_PushFont(ctx,nil,16)
      if r.ImGui_BeginTable(ctx,'Transport header',2,r.ImGui_TableFlags_SizingStretchProp()) then
        r.ImGui_TableSetupColumn(ctx,'State',r.ImGui_TableColumnFlags_WidthStretch())
        r.ImGui_TableSetupColumn(ctx,'Controls',r.ImGui_TableColumnFlags_WidthFixed(),240)
        r.ImGui_TableNextRow(ctx); r.ImGui_TableNextColumn(ctx)
        local nextslot
        for _,s in ipairs(state.slots) do if s.status=='Scheduled' and (not nextslot or Core.bounds(s)<Core.bounds(nextslot)) then nextslot=s end end
        status(engine.active and 'Recording' or (state.enabled and 'Enabled' or (ready and 'Ready' or 'Not ready')))
        if engine.active then
          text(engine.active.name)
          local _,ending=Core.bounds(engine.active)
          muted(ending and ('Remaining  '..duration(ending-now)) or 'Open-ended / manual stop')
        elseif nextslot then
          text('Next: '..nextslot.name)
          muted(stamp(nextslot.start)..'  /  in '..duration(Core.bounds(nextslot)-now))
        else text('No upcoming recordings') end
        r.ImGui_TableNextColumn(ctx)
        if engine.active then
          if r.ImGui_Button(ctx,'Stop recording',-1,0) then engine:stop(now) end
          if engine.active and engine.active.finish and r.ImGui_Button(ctx,'Extend by 5 min',-1,0) then local ok,err=engine:extend(now,300); if not ok then error=err end end
        elseif state.enabled then
          if r.ImGui_Button(ctx,'Disable schedule',-1,0) then engine:disable(now) end
        else
          r.ImGui_BeginDisabled(ctx,not ready or loaderr~=nil or editor_open)
          if r.ImGui_Button(ctx,'Enable schedule',-1,0) then save(); local ok,err=engine:enable(now); if not ok then error=err end end
          r.ImGui_EndDisabled(ctx)
          if not ready and r.ImGui_Button(ctx,'Review setup',-1,0) then view='Setup' end
        end
        if engine.active and state.enabled and r.ImGui_Button(ctx,'Disable future starts',-1,0) then engine:disable(now) end
        r.ImGui_EndTable(ctx)
      end
      local project_name=r.GetProjectName(project,'')
      muted((project_name~='' and project_name or 'Unsaved project')..'  /  '..#host:tracks()..' armed tracks  /  '..(state.mode=='continuous' and 'Continuous live' or 'Separate slots'))
      if not engine.active and not ready then text(readiness) end
      if loaderr then text(loaderr) end
      if host.storage_error then text(host.storage_error) end
      if close_requested then
        text('Close scheduler? The current recording will stop and future starts will be disabled. Your plan is retained.')
        if r.ImGui_Button(ctx,'Stop and close') then if engine:stop(now,'Scheduler closed by user.') then quit=true end end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx,'Keep running') then close_requested=false end
      end
      r.ImGui_Separator(ctx)
      for _,name in ipairs({'Schedule','Setup','Activity'}) do
        if name~='Schedule' then r.ImGui_SameLine(ctx) end
        if r.ImGui_Selectable(ctx,name,view==name,0,100,26) then view=name end
      end
      r.ImGui_Separator(ctx)
      if view=='Schedule' then draw_schedule(now)
      elseif view=='Setup' then draw_setup()
      else draw_activity() end
      r.ImGui_PopFont(ctx)
      r.ImGui_End(ctx)
    end
    r.ImGui_PopStyleVar(ctx,5)
    if not open then if state.enabled or engine.active then close_requested=true else quit=true end end
    return not quit
  end
  local function cleanup()
    if host:valid() then
      if engine.active then engine:stop(os.time(),'Scheduler terminated. Inspect recorded files.') end
      if host.owns_transport and host:recording() then host:stop() end
      host:restore(); save()
    end
    if r.GetExtState(section,lockkey)==token then r.DeleteExtState(section,lockkey,false) end
  end
  exit_handler=cleanup
  local function loop()
    local ok,err=xpcall(function()
      local now=os.time()
      if not engine:tick(now,r.time_precise()) then return end
      if now~=last_check then ready,readiness=host:preflight(true); readiness=readiness or ''; last_check=now end
      save()
      if draw(now) then save(); r.defer(loop) end
    end,debug.traceback)
    if not ok then cleanup(); r.ShowMessageBox('Scheduler stopped after an error. Check the recorded files.\n\n'..tostring(err),'Recording Scheduler',0) end
  end
  loop()
end

if ...=='__test' then return {Core=Core,Engine=Engine,Host=Host,run=run} end
run(reaper)
