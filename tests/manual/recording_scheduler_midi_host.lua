-- Native MIDI input probe, using the virtual MIDI keyboard in an isolated instance.
-- Launch with -newinst -cfgfile /tmp/jg-pause-probe/reaper.ini -new <this script>.
-- Saves only the disposable midi-probe.rpp in that resource directory.
local r=reaper
local root='/tmp/jg-pause-probe'
assert(r.GetResourcePath()==root and r.CountTracks(0)==0)
local directory=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local M=assert(loadfile(directory..'/../../Tools/JG_Recording_Scheduler.lua'))('__test')
local project=r.EnumProjects(-1,'')
for i=0,1 do
 r.InsertTrackAtIndex(i,false); local t=r.GetTrack(project,i)
 r.GetSetMediaTrackInfo_String(t,'P_NAME','MIDI Probe '..i,true)
 r.SetMediaTrackInfo_Value(t,'I_RECINPUT',4096+62*32)
 r.SetMediaTrackInfo_Value(t,'I_RECMODE',0)
 r.SetMediaTrackInfo_Value(t,'I_RECARM',1)
 r.SetMediaTrackInfo_Value(t,'I_RECMON',1)
 r.SetMediaTrackInfo_Value(t,'B_MAINSEND',0)
end
r.Main_SaveProjectEx(project,root..'/midi-probe.rpp',8)
local h=M.Host.new(r,project)
assert(h:project_file()==root..'/midi-probe.rpp')
local st=M.Core.new(); st.root=root..'/midi-capture'; local first=os.time()+4
for i=0,1 do st.slots[#st.slots+1]={id=i+1,name='MIDI Slot '..i,start=first+i*5,finish=first+i*5+3,pre=0,post=0,status='Scheduled',note=''} end
st.next_id=3
local e=M.Engine.new(st,h); e:watch(os.time())
local f=assert(io.open(root..'/midi-result.txt','w')); local function log(s) f:write(s..'\n'); f:flush() end
local last=0; local on=false
local function loop()
 local now=os.time(); local precise=r.time_precise()
 local ok,err=pcall(function()
  e:tick(now,precise)
  if h:recording() and precise-last>0.2 then
   on=not on; r.StuffMIDIMessage(0,on and 0x90 or 0x80,60,on and 100 or 0)
   r.StuffMIDIMessage(0,0xB0,1,64); last=precise
  end
 end)
 if not ok then r.OnStopButtonEx(project); log('ERROR '..err); f:close(); return end
 if now>=first+8 then
  r.StuffMIDIMessage(0,0x80,60,0)
  for _,s in ipairs(st.slots) do log('slot '..s.id..' '..s.status..' '..s.note) end
  log('project dirty='..r.IsProjectDirty(project))
  local count=0
  for i=0,r.CountMediaItems(project)-1 do
   local item=r.GetMediaItem(project,i); local take=r.GetActiveTake(item)
   local valid,notes,cc,sysex=r.MIDI_CountEvts(take); count=count+notes+cc+sysex
   log('item '..i..' notes='..notes..' cc='..cc..' position='..r.GetMediaItemInfo_Value(item,'D_POSITION'))
  end
  assert(st.slots[1].status=='Completed' and st.slots[2].status=='Completed')
  assert(r.CountMediaItems(project)==4 and count>0)
  local disk=assert(io.open(root..'/midi-probe.rpp','rb')); local text=disk:read('*a'); disk:close()
  local _,sources=text:gsub('<SOURCE MIDI',''); assert(sources==4,'Recorded MIDI was not saved to project')
  log('saved MIDI sources='..sources); log('DONE'); f:close(); return
 end
 r.defer(loop)
end
r.defer(loop)
