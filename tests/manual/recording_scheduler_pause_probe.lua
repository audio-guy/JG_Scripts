-- Manual host probe. Run only in a disposable REAPER instance with
-- -newinst -cfgfile /tmp/jg-pause-probe/reaper.ini -new <this script>.
-- Requires Effects/probe.jsfx in that isolated resource directory.
-- Never run in a production project. No track output is sent to the master.
local r=reaper
local root='/tmp/jg-pause-probe'
assert(r.GetResourcePath()==root,'Not the isolated test instance')
assert(r.CountTracks(0)==0,'The probe requires an empty disposable project')
local out=assert(io.open(root..'/result.txt','w'))
local function log(s) out:write(s..'\n'); out:flush() end
log('version '..r.GetAppVersion()..' resource '..r.GetResourcePath())
local p=r.EnumProjects(-1,'')
r.GetSetProjectInfo_String(p,'RECORD_PATH',root,true)

for i=0,1 do
 r.InsertTrackAtIndex(i,false)
 local t=r.GetTrack(p,i)
 r.GetSetMediaTrackInfo_String(t,'P_NAME','Probe'..i,true)
 r.SetMediaTrackInfo_Value(t,'B_MAINSEND',0)
 r.SetMediaTrackInfo_Value(t,'I_RECARM',1)
 r.SetMediaTrackInfo_Value(t,'I_RECMODE',1)
 r.SetMediaTrackInfo_Value(t,'I_RECINPUT',-1)
 log('fx '..r.TrackFX_AddByName(t,'probe',false,1))
end
local function snapshot(label)
 log(label..' state='..r.GetPlayStateEx(p)..' pos='..r.GetPlayPositionEx(p)..' processpos='..r.GetPlayPosition2Ex(p))
 for j=0,r.CountMediaItems(p)-1 do
  local item=r.GetMediaItem(p,j)
  log('live item '..j..' length='..r.GetMediaItemInfo_Value(item,'D_LENGTH'))
 end
 local i=0
 while true do local f=r.EnumerateFiles(root,i); if not f then break end
 if f:lower():match('%.wav$') then local h=io.open(root..'/'..f,'rb'); if h then log(f..' bytes='..h:seek('end')); h:close() end end
 i=i+1 end
end
local stage=-1; local mark=r.time_precise()
local function loop()
 if r.time_precise()-mark<3 then r.defer(loop); return end
 stage=stage+1; mark=r.time_precise()
 if stage==0 then r.Main_OnCommandEx(1013,0,p); snapshot('started')
 elseif stage==1 then snapshot('before pause'); r.Main_OnCommandEx(1008,0,p); snapshot('paused')
 elseif stage==2 then snapshot('pause end'); r.Main_OnCommandEx(1008,0,p); snapshot('resumed')
 elseif stage==3 then snapshot('before stop'); r.OnStopButtonEx(p); snapshot('stopped')
 for i=0,r.CountMediaItems(p)-1 do
 local item=r.GetMediaItem(p,i); local take=r.GetActiveTake(item)
 log('item '..i..' pos='..r.GetMediaItemInfo_Value(item,'D_POSITION')..' length='..r.GetMediaItemInfo_Value(item,'D_LENGTH')..' source='..r.GetMediaSourceFileName(r.GetMediaItemTake_Source(take),'')..' offset='..r.GetMediaItemTakeInfo_Value(take,'D_STARTOFFS'))
 end
 log('DONE'); out:close(); return
 end
 r.defer(loop)
end
r.defer(loop)
