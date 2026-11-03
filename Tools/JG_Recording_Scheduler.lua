-- @description Recording Scheduler
-- @author Julius Gass
-- @version 2.6.12
-- @changelog
--   Remove the retired Shared WAV engine; retain historical plan compatibility.
--   Remove the duplicate transport header; use REAPER transport to stop a slot.
--   Open Add slot with Enter in the focused schedule view.
--   Remove band-folder export; slots already record directly into their own folders.
--   Accept compact HHMMSS input for slot start and end times.
--   Record slot folders directly beside the saved project; remove destination settings.
--   Focus the name field immediately when opening Add slot.
--   Hide the transport header when no recording is active or scheduled.
--   Allow MIDI input recording, verify new MIDI events, and save embedded MIDI with the project.
--   Confirm the recording interruption before saving directly adjacent slots.
--   Remove Shared WAV from scheduling; migrate plans to separate clock-aligned slots.
--   Preserve historical capture maps and band export.
--   Pause between slots in Shared WAV mode; resume the same source files without rendering.
--   Place recorded sections at clock times after stopping, preserving original WAV data.
--   Preserve field edits when tabbing; detect Enter separately from text updates.
--   Use numbered Slot names for blank names and allow adding slots during recording in both modes.
--   Show a remaining-time countdown in the slot list during recording.
--   Save slot forms with Enter from any input field, preserving overlap confirmation.
--   Edit the running slot name/end directly and update its band region and stop time.
--   Remove Extend by 5 min.
--   Always watch schedules while open; remove Pause/Resume controls.
--   Edit slots by double-click and align date/time labels and inputs in shared rows.
--   Treat blank end times as open-ended; offer confirmed shortening of an overlapping predecessor.
--   Stop ordinary playback automatically before a scheduled recording; protect existing recordings.
--   Replace tabs with one schedule view, collapsible settings and an optional activity window.
--   Remove Recording help.
--   Place recordings by clock time on the timeline; preserve a project reference day.
--   Reject collisions on armed tracks instead of appending after existing material.
--   Add explicit continuous recording, editable band regions and raw WAV band export.
--   Remove templates from the slot editor; use Duplicate for similar slots.
--   Allow deleting inactive slots without touching audio; remove redundant slot details.
--   Require a saved project when saving or resuming a schedule.
--   Allow rescheduling missed slots, including when their start passes during editing.
--   Schedule saved slots automatically; allow adding slots while waiting.
--   Show save errors beside the form action and distinguish Add from Save.
--   Display the running version in the window title while preserving window settings.
--   Compact operator UI; remove onboarding copy and show actionable errors once.
--   Simplify slots to direct start/end times; remove repetition and confirmation checklists.
--   Always record each slot into its own YYMMDD - HHMM Name subfolder.
--   Add a native folder picker (requires js_ReaScriptAPI for the dialog).
-- @about
--   For unattended audio recordings and attended live capture. Requires ReaImGui 0.10+.
--   Save the project first. Prepare audio inputs, normal record mode, no record length
--   limit, and automatic retention of recorded files. Keep REAPER running and prevent sleep.
--   Each slot records into its own folder at its clock-time position.
--   Timing is wall-clock/defer based, not sample accurate.
--   Plans are stored in project extstate and a recovery sidecar next to the saved project.

local VERSION = '2.6.12' -- Keep in sync with the ReaPack @version above.
local WINDOW_TITLE = 'Recording Scheduler v'..VERSION..'###Recording Scheduler'
local Core = {}
local function copy(t) local r = {}; for k,v in pairs(t) do r[k]=v end; return r end
local function trim(s) return (s or ''):match('^%s*(.-)%s*$') end
local function clocktime(t) return os.date(t%60==0 and '%H:%M' or '%H:%M:%S',t) end
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
  local h,n,sec=time:match('^(%d%d):(%d%d):(%d%d)$')
  if not h then h,n,sec=time:match('^(%d%d)(%d%d)(%d%d)$') end
  if not h then h,n=time:match('^(%d%d):(%d%d)$') end
  sec=tonumber(sec) or 0
  if not h then h,n=time:match('^(%d%d)(%d%d)$') end
  y,m,d,h,n=tonumber(y),tonumber(m),tonumber(d),tonumber(h),tonumber(n)
  if not y or not h or y<2000 or y>2099 or m<1 or m>12 or d<1 or d>31 or h>23 or n>59 or sec>59 then
    return nil,'Enter a valid date (YYMMDD) and time (HH:MM, HH:MM:SS, HHMM or HHMMSS).'
  end
  local matches={}
  for _,dst in ipairs({false,true}) do
    local ok,t=pcall(os.time,{year=y,month=m,day=d,hour=h,min=n,sec=sec,isdst=dst})
    if ok and t then
      local v=os.date('*t',t)
      if v.year==y and v.month==m and v.day==d and v.hour==h and v.min==n and v.sec==sec then matches[t]=true end
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
function Core.midnight(t)
  local day=os.date('*t',t); day.hour,day.min,day.sec,day.isdst=0,0,0,nil
  return os.time(day)
end
function Core.bounds(s) return s.start-s.pre, s.finish and s.finish+s.post end
function Core.make(form,default_name)
  local name=trim(form.name)=='' and (default_name or 'Slot 1') or form.name
  local start,err=Core.datetime(form.date,form.start); if not start then return nil,err end
  local finish
  if trim(form.finish or '')~='' then
    local enddate=trim(form.enddate or '')
    if enddate=='' then enddate=form.date end
    finish,err=Core.datetime(enddate,form.finish or '')
    if not finish then return nil,'End: '..err end
    if finish<=start then return nil,'End must be after start. For overnight recordings, enter the next date.' end
  end
  return {id=0,name=name,start=start,finish=finish,pre=0,post=0,status='Scheduled',note='',actual_start=nil,actual_end=nil,folder=''}
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
function Core.adjacent(state,draft,replace_id)
  local check={draft}; local adjacent=false
  for _,slot in ipairs(state.slots) do
    if slot.id~=replace_id and (slot.status=='Scheduled' or slot.status=='Recording') then
      local candidate=copy(slot); candidate.status='Scheduled'; check[#check+1]=candidate
      if slot.finish==draft.start or (draft.finish and draft.finish==slot.start) then adjacent=true end
    end
  end
  -- Resolve overlaps first; shortening a predecessor has its own confirmation.
  return adjacent and not Core.conflict(check)
end
function Core.new()
  return {slots={},log={},templates={},next_id=1,enabled=false,mode='separate',root='',revision=0,captures={}}
end
function Core.add_log(state,now,message)
  state.log[#state.log+1]={time=now,message=message}; state.revision=state.revision+1
end
function Core.can_edit(s)
  return not s.actual_start and (s.status=='Scheduled' or s.status=='Missed')
end
function Core.apply(state, additions, replace_id, trim_id)
  local nextslots={}; local trimmed=not trim_id
  for _,s in ipairs(state.slots) do
    if s.id==trim_id then
      local draft=additions[1]; local begin,ending=Core.bounds(s)
      if #additions~=1 or s.id==replace_id or not Core.can_edit(s) or s.status~='Scheduled' or begin>=draft.start or (ending and ending<=draft.start) then
        return nil,'The overlapping slot changed. Review the times again.'
      end
      s=copy(s); s.finish=draft.start; s.post=0; trimmed=true
    end
    if s.id~=replace_id then nextslots[#nextslots+1]=s
    elseif not Core.can_edit(s) then return nil,'This slot has already run or attempted to record. Duplicate it to schedule another recording.' end
  end
  if not trimmed then return nil,'The overlapping slot no longer exists.' end
  for _,s in ipairs(additions) do nextslots[#nextslots+1]=copy(s) end
  local a,b=Core.conflict(nextslots)
  if a then return nil,'Overlap: '..a.name..' / '..b.name..'. Adjust the times before saving.' end
  local nextid=state.next_id
  for i=#nextslots-#additions+1,#nextslots do
    nextslots[i].id=nextid; nextid=nextid+1
  end
  table.sort(nextslots,function(x,y) return x.start<y.start end)
  state.slots=nextslots; state.next_id=nextid; state.revision=state.revision+1
  return true
end

function Core.offer_trim(state,draft,replace_id)
  for _,previous in ipairs(state.slots) do
    local begin,ending=Core.bounds(previous)
    if previous.id~=replace_id and previous.status=='Scheduled' and begin<draft.start and (not ending or ending>draft.start) then
      local trial=copy(state)
      if Core.apply(trial,{draft},replace_id,previous.id) then
        return {id=previous.id,name=previous.name,finish=draft.start,revision=state.revision}
      end
    end
  end
end

-- A versioned, escaped data format; never execute stored project data as Lua.
function Core.serialize(st)
  local out={row('JG_RECORDING_SCHEDULER',4),row('P',st.mode,st.root,st.next_id,st.revision,'0',st.timeline_origin or '')}
  for _,s in ipairs(st.slots) do out[#out+1]=row('S',s.id,s.name,s.start,s.finish or '',s.pre,s.post,s.status,s.note,s.actual_start or '',s.actual_end or '',s.folder or '') end
  for _,c in ipairs(st.captures or {}) do
    out[#out+1]=row('C',c.id,c.wall,c.position,c.folder,c.error or '')
    for _,g in ipairs(c.segments or {}) do out[#out+1]=row('G',c.id,g.offset,g.position,g.finish or '') end
    for _,b in ipairs(c.bands) do out[#out+1]=row('B',c.id,b.region,b.start,b.name) end
    for _,f in ipairs(c.files) do out[#out+1]=row('F',c.id,f.track,f.name,f.path,f.position,f.offset,f.length) end
  end
  for _,e in ipairs(st.log) do out[#out+1]=row('L',e.time,e.message) end
  for _,t in ipairs(st.templates) do out[#out+1]=row('T',t.name,t.start,t.finish,t.open and '1' or '0',t.pre,t.post,t.enddays or 0) end
  return table.concat(out,'\n')..'\n'
end
function Core.deserialize(text)
  if not text or text=='' then return Core.new() end
  local st=Core.new(); local first=true; local ids={}; local version; local captures={}
  local statuses={Scheduled=true,Recording=true,Starting=true,Completed=true,Partial=true,Stopped=true,Missed=true,Failed=true,Interrupted=true,['In session']=true,Captured=true}
  for line in text:gmatch('[^\n]+') do
    local f=fields(line)
    if first then
      if f[1]~='JG_RECORDING_SCHEDULER' or (f[2]~='2' and f[2]~='3' and f[2]~='4') then return nil,'Unsupported or damaged schedule data.' end
      version=tonumber(f[2]); first=false
    elseif f[1]=='P' then
      if f[2]~='separate' and f[2]~='continuous' then return nil,'Invalid recording mode in saved plan.' end
      -- Shared capture maps remain readable, but all future slots record separately.
      st.mode,st.root,st.next_id,st.revision='separate',f[3],tonumber(f[4]),tonumber(f[5])
      -- Ignore the obsolete pause flag from earlier versions.
      st.timeline_origin=tonumber(f[7])
      if f[7] and f[7]~='' and not finite(st.timeline_origin) then return nil,'Invalid timeline reference day.' end
      if not finite(st.next_id) or st.next_id<1 or not finite(st.revision) then return nil,'Invalid plan metadata.' end
    elseif f[1]=='S' then
      local s={id=tonumber(f[2]),name=f[3],start=tonumber(f[4]),finish=tonumber(f[5]),pre=tonumber(f[6]),post=tonumber(f[7]),status=f[8],note=f[9],actual_start=tonumber(f[10]),actual_end=tonumber(f[11]),folder=f[12]}
      if #f~=12 or not finite(s.id) or s.id%1~=0 or ids[s.id] or not finite(s.start) or not finite(s.pre) or not finite(s.post) or s.pre<0 or s.post<0 or s.pre>3600 or s.post>3600 or not statuses[s.status] or (f[5]~='' and (not finite(s.finish) or s.finish<=s.start)) then return nil,'Invalid slot in saved plan.' end
      -- Preserve effective times from older plans while removing hidden margins.
      if s.status=='Scheduled' and (s.pre~=0 or s.post~=0) then
        s.start,s.finish=Core.bounds(s); s.pre,s.post=0,0
        s.note='Previous pre/post-roll included in the displayed start/end times.'
      end
      ids[s.id]=true; st.next_id=math.max(st.next_id,s.id+1)
      st.slots[#st.slots+1]=s
    elseif f[1]=='C' and (#f==5 or #f==6) then
      if captures[f[2]] or not finite(tonumber(f[3])) or not finite(tonumber(f[4])) then return nil,'Invalid capture metadata.' end
      local c={id=f[2],wall=tonumber(f[3]),position=tonumber(f[4]),folder=f[5],error=f[6] or '',bands={},files={}}
      captures[c.id]=c; st.captures[#st.captures+1]=c
    elseif f[1]=='G' and #f==5 then
      local c=captures[f[2]]
      local g={offset=tonumber(f[3]),position=tonumber(f[4]),finish=tonumber(f[5])}
      if not c or not finite(g.offset) or g.offset<0 or not finite(g.position) or
        (f[5]~='' and (not finite(g.finish) or g.finish<g.offset)) then return nil,'Invalid capture segment.' end
      c.segments=c.segments or {}; c.segments[#c.segments+1]=g
    elseif f[1]=='B' and #f==5 then
      local c=captures[f[2]]
      if not c or not finite(tonumber(f[3])) or not finite(tonumber(f[4])) then return nil,'Invalid band region.' end
      c.bands[#c.bands+1]={region=tonumber(f[3]),start=tonumber(f[4]),name=f[5]}
    elseif f[1]=='F' and #f==8 then
      local c=captures[f[2]]
      if not c or not finite(tonumber(f[6])) or not finite(tonumber(f[7])) or not finite(tonumber(f[8])) then return nil,'Invalid captured file.' end
      c.files[#c.files+1]={track=f[3],name=f[4],path=f[5],position=tonumber(f[6]),offset=tonumber(f[7]),length=tonumber(f[8])}
    elseif f[1]=='L' and tonumber(f[2]) then st.log[#st.log+1]={time=tonumber(f[2]),message=f[3]}
    elseif f[1]=='T' and #f==8 then
      st.templates[#st.templates+1]={name=f[2],start=f[3],finish=f[4],open=f[5]=='1',pre=f[6],post=f[7],enddays=tonumber(f[8]) or 0}
    else return nil,'Damaged schedule data.' end
  end
  if first or Core.conflict(st.slots) then return nil,'Empty or overlapping saved plan.' end
  for _,s in ipairs(st.slots) do
    if s.status=='Recording' or s.status=='Starting' or s.status=='In session' or s.status=='Captured' then s.status='Interrupted'; s.note='Previous scheduler session ended. Inspect the audio files before continuing.' end
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
-- Watching a plan does not bypass readiness checks at the actual recording start.
function Engine:watch(now)
  local pending=false
  for _,slot in ipairs(self.state.slots) do
    if slot.status=='Scheduled' then
      if Core.bounds(slot)<=now then
        slot.status='Missed'; slot.note='Start passed while the scheduler was closed or unavailable.'
        self:log(now,Core.folder(slot)..': '..slot.note)
      else pending=true end
    end
  end
  self.state.enabled=pending
  if pending then self:log(now,'Watching scheduled slots.') end
end
function Engine:finalize(now,requested,reason)
  local ok,detail=self.host:verify()
  for _,s in ipairs(self.session) do
    local _,ending=Core.bounds(s)
    s.actual_end=now
    if not s.actual_start then s.status='Interrupted'; s.note='Recording stopped before this slot began.'; s.actual_end=nil
    elseif not ok then s.status='Failed'; s.note=detail
    elseif requested~='Completed' and (not ending or now<ending) then s.status=requested; s.note=reason
    elseif s.note~='' then s.status='Partial'
    else s.status='Completed'; s.note='Recording verified on every expected track. Review the captured content.' end
    self:log(now,Core.folder(s)..': '..s.status..'. '..(s.note or ''))
  end
  for _,path in ipairs(self.host.result_files or {}) do self:log(now,'Recorded file: '..path) end
  self.host:restore()
  if self.host.save_recorded_midi then
    local saved,problem=self.host:save_recorded_midi()
    if not saved then
      for _,slot in ipairs(self.session) do if slot.actual_start then slot.status='Failed'; slot.note=problem end end
      self:log(now,problem)
    end
  end
  self.session={}; self.active=nil
end
function Engine:start_session(s,now)
  local ok,err=self.host:preflight(false)
  local origin=self.state.timeline_origin or Core.midnight(now)
  if ok then ok,err=self.host:start(s,self.state.root,now,origin) end
  if not ok or not self.host:recording() then
    s.status='Failed'; s.note=err or 'REAPER did not enter recording.'
    self.host:restore(); self:disable(now,Core.folder(s)..': '..s.note); return
  end
  self.state.timeline_origin=origin
  self.active=s; self.session={s}
  s.actual_start=now; s.status='Recording'
  if now-s.start>2 then s.note='Recording started '..(now-s.start)..' seconds late.' end
  self.host:marker(s)
  self:log(now,s.name..': Recording to '..s.folder)
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
function Engine:live_slot(id)
  if not self.active then return nil end
  for _,slot in ipairs(self.session) do
    if slot.id==id and slot.status=='Recording' then return slot end
  end
end
function Engine:edit_live(id,draft,now)
  local slot=self:live_slot(id)
  if not slot then return nil,'This slot is no longer recording. Its recording history cannot be changed.' end
  if draft.start~=slot.start then return nil,'The start of a running recording cannot be changed.' end
  if draft.finish and draft.finish<=now then return nil,'End must be in the future. Use the REAPER transport to stop now.' end
  local check={}
  for _,v in ipairs(self.state.slots) do
    if v==slot or v.status=='Scheduled' then
      local candidate=copy(v==slot and draft or v); candidate.status='Scheduled'; check[#check+1]=candidate
    end
  end
  local a,b=Core.conflict(check)
  if a then return nil,'Overlap: '..a.name..' / '..b.name..'. Adjust the end before saving.' end
  slot.name,slot.finish=draft.name,draft.finish
  self:log(now,'Updated running slot: '..slot.name..'. End: '..(slot.finish and os.date('%y%m%d %H:%M:%S',slot.finish) or 'manual stop'))
  return true
end
function Engine:append_live(draft,now,trim_id)
  if not self.active then return nil,'The recording has ended. Save the slot again.' end
  if draft.start<=now then return nil,'Start must be in the future.' end
  -- Validate against the running slot as well as the pending plan, without
  -- changing transport ownership or its recording history during validation.
  local trial=copy(self.state); trial.slots={}
  for _,s in ipairs(self.state.slots) do
    local candidate=copy(s)
    if s==self.active then candidate.status='Scheduled'; candidate.actual_start=nil end
    trial.slots[#trial.slots+1]=candidate
  end
  local ok,err=Core.apply(trial,{draft},nil,trim_id)
  if not ok then return nil,err,Core.offer_trim(trial,draft) end
  for i,s in ipairs(trial.slots) do
    if s.id==self.active.id then
      self.active.finish,self.active.post=s.finish,s.post
      trial.slots[i]=self.active
    end
  end
  self.state.slots,self.state.next_id=trial.slots,trial.next_id
  self:log(now,'Added slot during recording: '..draft.name)
  return true
end
function Engine:tick(now,mono)
  if not self.host:valid() then
    if self.active then
      for _,s in ipairs(self.session) do s.status='Interrupted'; s.note='Target project closed.' end
      self:log(now,'Target project closed.')
    end
    self.state.enabled=false; return false
  end
  if self.last_wall and math.abs((now-self.last_wall)-(mono-self.last_mono))>3 then
    self.clock_hold=true
    self:disable(now,'System clock changed. Check the clock and reopen the scheduler.')
    if self.active then self.active.note='System clock changed during recording; review timing.' end
  end
  self.last_wall,self.last_mono=now,mono
  if self.state.enabled and not self.host:selected() then self:disable(now,'Target project is no longer selected. Future starts disabled; active recording keeps its end.') end
  if self.active then
    local s=self.active
    local paused=self.host.paused and self.host:paused()
    if paused then
      self:stop(now,'Recording was paused outside the scheduler. Inspect the recorded duration.'); return true
    end
    if not self.host:recording() then
      self:disable(now,'Recording stopped outside the scheduler.')
      self:finalize(now,'Stopped','Recording stopped before the scheduled end.'); return true
    end
    local _,ending=Core.bounds(s)
    if ending and now>=ending then
        self.host:stop()
        if self.host:recording() then
          if not self.stop_warning then self:disable(now,'Automatic stop failed. Use REAPER transport.'); self.stop_warning=true end
          return true
        end
        if now-ending>2 then s.note='Automatic stop was late by '..(now-ending)..' seconds.' end
        self:finalize(now,'Completed','')
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
          self:start_session(s,now)
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
function Host.new(api,project) return setmetatable({r=api,project=project,baseline={},expected={},saved=nil},Host) end
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
  if (r.GetPlayStateEx(self.project)&4)~=0 then return nil,'Another recording is already running. It will not be stopped or taken over.' end
  local tracks=self:tracks()
  if #tracks==0 then return nil,'Arm at least one audio or MIDI track.' end
  for _,t in ipairs(tracks) do
    local input=r.GetMediaTrackInfo_Value(t,'I_RECINPUT')
    if input<0 or r.GetMediaTrackInfo_Value(t,'I_RECMODE')~=0 then return nil,'Armed tracks must have an audio or MIDI input and use Record: input (audio or MIDI).' end
  end
  local device=r.GetAudioDeviceInfo('SRATE')
  if not device then return nil,'The audio device is not open.' end
  if r.GetSetRepeatEx(self.project,-1)~=0 then return nil,'Disable loop/repeat before enabling the schedule.' end
  if self.storage_error then return nil,self.storage_error end
  return true
end
local function join(a,b) return a:gsub('[/\\]+$','')..'/'..b end
function Host:root_path()
  -- Always use the RPP directory, not REAPER's separate media/recording path.
  local file=self:project_file()
  local directory=file:match('^(.*)[/\\]') or ''
  if directory=='' and file:sub(1,1)=='/' then return '/' end
  return directory
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
function Host:midi_map()
  local result={}; local r=self.r
  for _,track in ipairs(self.expected) do
    if r.ValidatePtr2(self.project,track,'MediaTrack*') then
      for i=0,r.CountTrackMediaItems(track)-1 do
        local item=r.GetTrackMediaItem(track,i)
        for j=0,r.CountTakes(item)-1 do
          local take=r.GetTake(item,j)
          if take and r.TakeIsMIDI(take) then
            local _,guid=r.GetSetMediaItemTakeInfo_String(take,'GUID','',false)
            local valid,notes,cc,sysex=r.MIDI_CountEvts(take)
            if guid and guid~='' then result[guid]={track=track,length=r.GetMediaItemInfo_Value(item,'D_LENGTH'),
              events=valid and valid~=0 and (notes+cc+sysex) or 0} end
          end
        end
      end
    end
  end
  return result
end
function Host:save_recorded_midi()
  if not self.midi_needs_save then return true end
  self.midi_needs_save=false
  if not self:valid() or self:project_file()=='' then return nil,'MIDI is in memory. Save the recording project before closing REAPER.' end
  self.r.Main_SaveProject(self.project,false)
  if self.r.IsProjectDirty(self.project)~=0 then return nil,'MIDI project save could not be confirmed. Save the project before closing REAPER.' end
  return true
end
function Host:start(slot,root,now,origin)
  local r=self.r
  if self:recording() then return nil,'Another recording is already running. It will not be stopped or taken over.' end
  now=now or slot.start; origin=origin or Core.midnight(now)
  local position=now-origin-r.GetProjectTimeOffset(self.project,false)
  if position<0 then return nil,'The recording time is before the project timeline start. Adjust the project start time.' end
  local ending=slot.finish and position+slot.finish-now or math.huge
  for _,track in ipairs(self:tracks()) do
    for i=0,r.CountTrackMediaItems(track)-1 do
      local item=r.GetTrackMediaItem(track,i)
      local begin=r.GetMediaItemInfo_Value(item,'D_POSITION')
      local finish=begin+r.GetMediaItemInfo_Value(item,'D_LENGTH')
      if begin<ending and finish>position then
        return nil,'Existing media overlaps the recording time on an armed track. Move it or use an empty recording track.'
      end
    end
  end
  local folder=Core.folder(slot)
  local path=join(self:root_path(root),folder)
  local ok,err=self:writable(path); if not ok then return nil,err end
  local _,oldpath=r.GetSetProjectInfo_String(self.project,'RECORD_PATH','',false)
  local _,tag=r.GetSetProjectInfo_String(self.project,'RECTAG','',false)
  self.saved={path=oldpath,tag=tag,newpath=path,newtag=Core.folder(slot)}
  self.expected=self:tracks(); self.baseline=self:source_map(); self.baseline_midi=self:midi_map(); self.midi_needs_save=false
  self.expected_settings={}
  for _,t in ipairs(self.expected) do self.expected_settings[t]={input=r.GetMediaTrackInfo_Value(t,'I_RECINPUT'),mode=r.GetMediaTrackInfo_Value(t,'I_RECMODE')} end
  local changed=r.GetSetProjectInfo_String(self.project,'RECORD_PATH',path,true)
  if not changed then self:restore(); return nil,'REAPER rejected the recording folder.' end
  r.GetSetProjectInfo_String(self.project,'RECTAG',self.saved.newtag,true)
  if r.GetPlayStateEx(self.project)~=0 then
    r.OnStopButtonEx(self.project)
    if r.GetPlayStateEx(self.project)~=0 then return nil,'Playback could not be stopped. Recording did not start.' end
  end
  -- Position follows the reference day and project display offset, never the cursor.
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
  local midi_seen={}
  for guid,item in pairs(self:midi_map()) do
    if not (self.baseline_midi or {})[guid] and item.length>0 then
      self.midi_needs_save=true -- Retain new MIDI items even if another track failed.
      if item.events>0 then midi_seen[item.track]=true end
    end
  end
  for _,t in ipairs(self.expected) do
    local settings=self.expected_settings and self.expected_settings[t]
    local input=settings and settings.input or self.r.GetMediaTrackInfo_Value(t,'I_RECINPUT')
    if (input&4096)~=0 then
      if not midi_seen[t] then return nil,'No new MIDI events could be confirmed on an expected track. Check its MIDI input and inspect the project.' end
    elseif not seen[t] then return nil,'Recorded audio files could not be confirmed on every expected audio track. Inspect the project and disk.' end
  end
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
  if not loaderr and host:project_file()~='' then engine:watch(os.time()) end
  local ctx=r.ImGui_CreateContext('Recording Scheduler',r.ImGui_ConfigFlags_NavEnableKeyboard())
  local form={date=os.date('%y%m%d'),start='',enddate=os.date('%y%m%d'),finish='',name='',pre='0',post='0'}
  local editing=nil; local error=loaderr or ''
  local close_requested=false; local show_history=false; local last_saved=-1; local last_check=0; local readiness=''; local ready=false
  local live_edit=false
  local pending_trim=nil
  local pending_adjacent=nil
  local focus_name=false
  local adjacency_warning="These slots meet without a gap. Starting a new recording file will cause a brief interruption."
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
  local function clear_form() focus_name=false; live_edit=false; pending_trim=nil; pending_adjacent=nil; editing=nil; form.start=''; form.finish=''; form.name=''; error='' end
  local function editable() return not engine.active end
  local function can_edit_slot(slot)
    return (not engine.active and Core.can_edit(slot)) or engine:live_slot(slot.id)~=nil
  end
  local function text(s) r.ImGui_TextWrapped(ctx,tostring(s)) end
  local function edit(s,duplicate)
    editing=not duplicate and s.id or nil
    s=copy(s); s.start,s.finish=Core.bounds(s); s.pre,s.post=0,0
    form={date=os.date('%y%m%d',s.start),start=clocktime(s.start),enddate=os.date('%y%m%d',s.finish or s.start),finish=s.finish and clocktime(s.finish) or '',name=s.name,pre=tostring(s.pre),post=tostring(s.post)}
    error=duplicate and 'Choose a new date/time for this duplicate.' or ''
  end
  local function export()
    local file=host:project_file(); if file=='' then error='Save the project first.'; return end
    local path=file..'.recording-log.tsv'; local f,err=io.open(path,'wb')
    if not f then error='Cannot export activity log: '..tostring(err); return end
    local out={row('Recording Scheduler activity log'),row('Project',file),row('Recording mode','Separate slots'),row('Slot','Planned start','Planned end','Actual start','Actual end','Status','Folder','Details')}
    for _,s in ipairs(state.slots) do out[#out+1]=row(s.name,stamp(s.start),stamp(s.finish),stamp(s.actual_start),stamp(s.actual_end),s.status,s.folder,s.note) end
    out[#out+1]=row('Time','Event')
    for _,e in ipairs(state.log) do out[#out+1]=row(os.date('%y%m%d - %H%M%S',e.time),e.message) end
    local ok=f:write(table.concat(out,'\n')..'\n'); local closed=f:close()
    error=ok and closed and ('Log exported: '..path) or 'Could not finish writing the activity log.'
  end
  local show_activity=false
  local editor_open=false
  local opened_with_enter=false
  local selected_id=nil
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
  local submit_on_enter=false
  local function input(key)
    if key=='name' and focus_name then r.ImGui_SetKeyboardFocusHere(ctx); focus_name=false end
    r.ImGui_SetNextItemWidth(ctx,-1)
    -- ReaImGui only returns the new buffer when InputText returns true.
    -- Keep normal change reporting so Tab/click never discards an edited field.
    local changed,value=r.ImGui_InputText(ctx,'##'..key,form[key])
    if not opened_with_enter and (r.ImGui_IsItemFocused(ctx) or r.ImGui_IsItemDeactivated(ctx)) and
      (r.ImGui_IsKeyPressed(ctx,r.ImGui_Key_Enter(),false) or r.ImGui_IsKeyPressed(ctx,r.ImGui_Key_KeypadEnter(),false)) then
      submit_on_enter=true
    end
    if changed and value~=form[key] then
      pending_trim=nil; pending_adjacent=nil
      -- Keep same-day dates in sync until the user deliberately chooses another end date.
      if key=='date' and form.enddate==form.date then form.enddate=value end
      form[key]=value
    end
  end
  local function field(label,key) text(label); input(key) end
  local function start_editor(s,duplicate)
    error=''; pending_adjacent=nil; pending_trim=nil
    if s then edit(s,duplicate) else clear_form(); form.date=os.date('%y%m%d'); form.enddate=form.date end
    live_edit=s and not duplicate and engine:live_slot(s.id)~=nil or false
    focus_name=not s
    editor_open=true
  end
  local function commit_form(now,confirm_trim,confirm_adjacent)
    if host:project_file()=='' then
      error='Save the REAPER project first (Cmd/Ctrl+S), then save the slot.'
      return
    end
    local s,err=Core.make(form,'Slot '..(editing or state.next_id))
    if s then
      if confirm_adjacent and (not pending_adjacent or pending_adjacent~=state.revision) then
        pending_adjacent=nil; error='The schedule changed. Save again to review adjacent slots.'; return
      end
      if not confirm_trim and not confirm_adjacent and (live_edit or s.start>now) and Core.adjacent(state,s,editing) then
        pending_adjacent=state.revision; error=''; return
      end
      if live_edit then
        local ok; ok,err=engine:edit_live(editing,s,now)
        if ok then clear_form(); editor_open=false; undo=nil; save() end
      elseif s.start<=now then err='Start must be in the future.'
      else
        if confirm_trim and (not pending_trim or pending_trim.revision~=state.revision) then
          pending_trim=nil; error='The schedule changed. Save again to review the overlap.'; return
        end
        local before=Core.serialize(state)
        local ok
        if engine.active then
          if editing then err='Only the currently recording slot can be edited during capture.'
          else ok,err,pending_trim=engine:append_live(s,now,confirm_trim and pending_trim.id or nil) end
        else ok,err=Core.apply(state,{s},editing,confirm_trim and pending_trim.id or nil) end
        if ok then
          undo=not engine.active and before or nil
          selected_id=state.next_id-1; clear_form(); editor_open=false
          save()
          if not engine.active and not loaderr and not host.storage_error and not engine.clock_hold then engine:watch(now) end
        else
          if not engine.active then pending_trim=Core.offer_trim(state,s,editing) end
        end
      end
    end
    error=err or ''
  end
  local function draw_editor(now)
    submit_on_enter=false
    text(editing and 'Edit slot' or 'New slot')
    field('Name  /  optional','name')
    if r.ImGui_BeginTable(ctx,'Slot times',2,r.ImGui_TableFlags_SizingStretchSame()) then
      -- Separate label/input rows prevent frame baseline carry-over between columns.
      for _,pair in ipairs({{{'Start date  /  YYMMDD','date'},{'Start time  /  HH:MM','start'}},{{'End date  /  YYMMDD','enddate'},{'End time  /  optional','finish'}}}) do
        r.ImGui_TableNextRow(ctx)
        for _,cell in ipairs(pair) do r.ImGui_TableNextColumn(ctx); text(cell[1]) end
        r.ImGui_TableNextRow(ctx)
        for _,cell in ipairs(pair) do
          r.ImGui_TableNextColumn(ctx)
          r.ImGui_BeginDisabled(ctx,live_edit and (cell[2]=='date' or cell[2]=='start'))
          input(cell[2]); r.ImGui_EndDisabled(ctx)
        end
      end
      r.ImGui_EndTable(ctx)
    end
    muted('Leave end time blank for manual stop.')
    local preview=Core.make(form,'Slot '..(editing or state.next_id))
    r.ImGui_Separator(ctx)
    if preview then
      local begin,ending=Core.bounds(preview)
      text('Folder: '..Core.folder(preview))
      muted(ending and duration(ending-begin) or 'Manual stop')
    end
    if pending_adjacent then
      text(adjacency_warning)
      if r.ImGui_Button(ctx,'Save anyway') then commit_form(now,false,true) end
      r.ImGui_SameLine(ctx)
      if r.ImGui_Button(ctx,'Keep editing') then pending_adjacent=nil; error='' end
    elseif pending_trim then
      text(adjacency_warning)
      text('End "'..pending_trim.name..'" at '..os.date('%y%m%d %H:%M:%S',pending_trim.finish)..' and save this slot?')
      if r.ImGui_Button(ctx,'Shorten and save') then commit_form(now,true) end
      r.ImGui_SameLine(ctx)
      if r.ImGui_Button(ctx,'Keep editing') then pending_trim=nil; error='' end
    elseif (r.ImGui_Button(ctx,editing and 'Save changes' or 'Save slot',140,0) or submit_on_enter) and not opened_with_enter then commit_form(now) end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx,'Cancel',90,0) then clear_form(); editor_open=false end
    if editor_open and error~='' then text(error) end
  end
  local function draw_schedule(now)
    if editor_open and (editable() or live_edit or not editing) then draw_editor(now); return end
    if r.ImGui_Button(ctx,'Add slot',110,0) then start_editor() end
    r.ImGui_SameLine(ctx)
    r.ImGui_BeginDisabled(ctx,not editable())
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
    if r.ImGui_Button(ctx,'Activity log') then show_activity=true end
    r.ImGui_SameLine(ctx)
    local changed,value=r.ImGui_Checkbox(ctx,'Show history',show_history); if changed then show_history=value end
    local _,height=r.ImGui_GetContentRegionAvail(ctx)
    local tableheight=math.max(150,height-(selected_id and 120 or 16))
    local flags=r.ImGui_TableFlags_RowBg()|r.ImGui_TableFlags_Resizable()|r.ImGui_TableFlags_ScrollY()
    if r.ImGui_BeginTable(ctx,'Schedule v2.1',6,flags,0,tableheight) then
      r.ImGui_TableSetupColumn(ctx,'Name',r.ImGui_TableColumnFlags_WidthStretch())
      for _,column in ipairs({{'Date',78},{'Start',64},{'End',64},{'Length / left',124},{'Status',110}}) do
        r.ImGui_TableSetupColumn(ctx,column[1],r.ImGui_TableColumnFlags_WidthFixed(),column[2])
      end
      r.ImGui_TableSetupScrollFreeze(ctx,0,1); r.ImGui_TableHeadersRow(ctx)
      local visible_count=0
      for _,s in ipairs(state.slots) do
        -- Failures remain visible even when successful history is hidden.
        local hidden=s.status=='Completed' or s.status=='Stopped'
        if show_history or not hidden then
          visible_count=visible_count+1
          r.ImGui_PushID(ctx,s.id); r.ImGui_TableNextRow(ctx,0,30)
          r.ImGui_TableNextColumn(ctx)
          if r.ImGui_Selectable(ctx,s.name..'##slot',selected_id==s.id,r.ImGui_SelectableFlags_SpanAllColumns()|r.ImGui_SelectableFlags_AllowDoubleClick()) then
            selected_id=s.id
            if r.ImGui_IsMouseDoubleClicked(ctx,0) and can_edit_slot(s) then start_editor(s,false) end
          end
          r.ImGui_TableNextColumn(ctx); r.ImGui_Text(ctx,os.date('%y%m%d',s.start))
          r.ImGui_TableNextColumn(ctx); r.ImGui_Text(ctx,clocktime(s.start))
          r.ImGui_TableNextColumn(ctx); r.ImGui_Text(ctx,s.finish and clocktime(s.finish) or 'Open')
          r.ImGui_TableNextColumn(ctx)
          if s.status=='Recording' then
            local _,ending=Core.bounds(s)
            r.ImGui_Text(ctx,ending and (duration(ending-now)..' left') or 'Manual stop')
          else r.ImGui_Text(ctx,s.finish and duration(s.finish-s.start) or '--') end
          r.ImGui_TableNextColumn(ctx); status(s.status)
          r.ImGui_PopID(ctx)
        end
      end
      if visible_count==0 then
        r.ImGui_TableNextRow(ctx); r.ImGui_TableNextColumn(ctx)
        text(#state.slots==0 and 'No slots' or 'No upcoming slots')
      end
      r.ImGui_EndTable(ctx)
    end
    local selected
    for _,s in ipairs(state.slots) do if s.id==selected_id then selected=s; break end end
    if selected then
      r.ImGui_BeginDisabled(ctx,not can_edit_slot(selected))
      if r.ImGui_Button(ctx,'Edit selected') then start_editor(selected,false) end
      r.ImGui_EndDisabled(ctx); r.ImGui_SameLine(ctx)
      r.ImGui_BeginDisabled(ctx,not editable())
      if r.ImGui_Button(ctx,'Duplicate') then start_editor(selected,true) end
      r.ImGui_SameLine(ctx); r.ImGui_BeginDisabled(ctx,selected.status=='Recording' or selected.status=='Starting')
      if r.ImGui_Button(ctx,'Delete') then
        snapshot()
        for i,s in ipairs(state.slots) do if s.id==selected.id then table.remove(state.slots,i); break end end
        state.revision=state.revision+1; selected_id=nil; clear_form()
      end
      r.ImGui_EndDisabled(ctx); r.ImGui_EndDisabled(ctx)
      if selected.note~='' then text(selected.note) end
    end
  end
  local function draw_activity()
    if r.ImGui_Button(ctx,'Export log') then export() end
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
    r.ImGui_PushStyleVar(ctx,r.ImGui_StyleVar_ItemSpacing(),10,6)
    r.ImGui_PushStyleVar(ctx,r.ImGui_StyleVar_CellPadding(),8,4)
    r.ImGui_PushStyleVar(ctx,r.ImGui_StyleVar_FrameRounding(),4)
    local visible,open=r.ImGui_Begin(ctx,WINDOW_TITLE,true)
    local quit=false
    if visible then
      opened_with_enter=false
      if not editor_open and not close_requested and r.ImGui_IsWindowFocused(ctx,r.ImGui_FocusedFlags_ChildWindows()) and
        (r.ImGui_IsKeyPressed(ctx,r.ImGui_Key_Enter(),false) or r.ImGui_IsKeyPressed(ctx,r.ImGui_Key_KeypadEnter(),false)) then
        start_editor(); opened_with_enter=true
      end
      r.ImGui_PushFont(ctx,nil,16)
      local project_name=r.GetProjectName(project,'')
      muted((project_name~='' and project_name or 'Unsaved project')..'  /  '..#host:tracks()..' armed tracks')
      -- One persistent message area, including the editor.
      local message=host.storage_error or loaderr or (not editor_open and error~='' and error)
      if engine.clock_hold then message='System clock changed. Check the clock and reopen the scheduler.' end
      if not message and not engine.active and not ready then message=readiness end
      if message and message~='' then text(message) end
      if close_requested then
        text('Stop the current recording and close the scheduler?')
        if r.ImGui_Button(ctx,'Stop and close') then if engine:stop(now,'Scheduler closed by user.') then quit=true end end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx,'Keep running') then close_requested=false end
      end
      r.ImGui_Separator(ctx)
      draw_schedule(now)
      r.ImGui_PopFont(ctx)
      r.ImGui_End(ctx)
    end
    if show_activity and open then
      r.ImGui_SetNextWindowSize(ctx,760,420,r.ImGui_Cond_FirstUseEver())
      local log_visible,log_open=r.ImGui_Begin(ctx,'Activity log###Recording Scheduler Activity',true)
      show_activity=log_open
      if log_visible then
        r.ImGui_PushFont(ctx,nil,16)
        draw_activity()
        r.ImGui_PopFont(ctx)
        r.ImGui_End(ctx)
      end
    end
    r.ImGui_PopStyleVar(ctx,5)
    if not open then
      if engine.active then close_requested=true
      else
        if state.enabled then engine:disable(now,'Scheduler closed. Future starts disabled.') end
        quit=true
      end
    end
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
      if not state.enabled and not engine.active and not engine.clock_hold and not loaderr and not host.storage_error and host:valid() and host:selected() and host:project_file()~='' then
        local pending=false
        for _,slot in ipairs(state.slots) do if slot.status=='Scheduled' then pending=true; break end end
        if pending then engine:watch(now) end
      end
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
