-- Native integration probe for an isolated REAPER instance only.
-- Requires /tmp/jg-pause-probe/Effects/probe.jsfx with slider1 as a DC level.
-- Launch with -newinst -cfgfile /tmp/jg-pause-probe/reaper.ini -new <this script>.
local r=reaper
local root='/tmp/jg-pause-probe'
assert(r.GetResourcePath()==root and r.CountTracks(0)==0)
local directory=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local M=assert(loadfile(directory..'/../../Tools/JG_Recording_Scheduler.lua'))('__test')
local st=M.Core.new(); st.root=root..'/integration'
local first=os.time()+4
for i=0,2 do st.slots[#st.slots+1]={id=i+1,name='Band '..(i+1),start=first+i*6,finish=first+i*6+3,pre=0,post=0,status='Scheduled',note=''} end
st.next_id=4
for i=0,1 do
 r.InsertTrackAtIndex(i,false); local t=r.GetTrack(0,i)
 r.GetSetMediaTrackInfo_String(t,'P_NAME','Track '..i,true)
 r.SetMediaTrackInfo_Value(t,'B_MAINSEND',0); r.SetMediaTrackInfo_Value(t,'I_RECARM',1)
 r.SetMediaTrackInfo_Value(t,'I_RECMODE',1); r.SetMediaTrackInfo_Value(t,'I_RECINPUT',-1)
 assert(r.TrackFX_AddByName(t,'probe',false,1)==0)
end
local h=M.Host.new(r,r.EnumProjects(-1,''))
-- Output recording supplies a deterministic signal, without microphones.
h.preflight=function() return true end
h.project_file=function() return root..'/integration.rpp' end
local original_place=h.place_capture
local unchanged=false
h.place_capture=function(self,c)
 local contents={}
 for _,path in ipairs(self.result_files) do local f=assert(io.open(path,'rb')); contents[path]=f:read('*a'); f:close() end
 local ok,err=original_place(self,c)
 for path,bytes in pairs(contents) do local f=assert(io.open(path,'rb')); assert(f:read('*a')==bytes,'Original WAV was changed'); f:close() end
 unchanged=true; return ok,err
end
local e=M.Engine.new(st,h); e:watch(os.time())
local f=assert(io.open(root..'/integration-result.txt','w'))
local function log(t) f:write(t..'\n'); f:flush() end
local stage=0; local previous=''
local function loop()
 local now=os.time()
 local value=now>=first+12 and 0.3 or (now>=first+6 and 0.2 or 0.1)
 for i=0,1 do r.TrackFX_SetParam(r.GetTrack(0,i),0,0,value) end
 local ok,err=pcall(function() e:tick(now,r.time_precise()) end)
 if not ok then r.OnStopButtonEx(0); log('ERROR '..err); f:close(); return end
 local state=tostring(e.active~=nil)..'/'..tostring(e.gap_paused)..'/'..r.GetPlayState()
 if state~=previous then log('state '..now..' '..state); previous=state end
 if now>=first+15 then
  for _,s in ipairs(st.slots) do log('slot '..s.id..' '..s.status..' '..s.note) end
  for _,c in ipairs(st.captures) do
   log('capture '..(c.error or ''))
   for _,g in ipairs(c.segments or {}) do log('segment offset='..g.offset..' position='..g.position..' finish='..tostring(g.finish)) end
   for _,v in ipairs(c.files) do log('file '..v.path..' pos='..v.position..' length='..v.length..' offset='..v.offset) end
  end
  for i=0,r.CountMediaItems(0)-1 do
   local item=r.GetMediaItem(0,i); local take=r.GetActiveTake(item)
   log('item '..i..' position='..r.GetMediaItemInfo_Value(item,'D_POSITION')..' length='..r.GetMediaItemInfo_Value(item,'D_LENGTH')..' offset='..r.GetMediaItemTakeInfo_Value(take,'D_STARTOFFS'))
  end
  log('original WAV bytes unchanged='..tostring(unchanged))
  local plan,err=h:export_plan(st,nil,root..'/integration-export-'..first)
  assert(plan,err); assert(#plan.jobs==6)
  for _,job in ipairs(plan.jobs) do log('export samples='..job.samples..' rate='..job.rate) end
  log('DONE'); f:close(); return
 end
 r.defer(loop)
end
r.defer(loop)
