local M=assert(loadfile('Tools/JG_Recording_Scheduler.lua'))('__test')
local C,E,H=M.Core,M.Engine,M.Host
local tests=0
local function test(name,fn) local ok,err=pcall(fn); if not ok then error(name..': '..tostring(err)) end; tests=tests+1; print('PASS '..name) end
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function form(extra)
  local f={name='Concert',date='261102',start='19:30',enddate='261102',finish='20:30',pre='0',post='0'}
  for k,v in pairs(extra or {}) do f[k]=v end; return f
end
local function slot(extra) return assert(C.make(form(extra))) end
local start=assert(C.datetime('261102','1930'))
local function rig(slots,mode)
  local state=C.new(); assert(C.apply(state,slots)); state.mode=mode or 'separate'
  local host={rec=false,valid_project=true,selected_project=true,ready=true,verified=true,starts=0,stops=0,markers=0,restores=0}
  function host:valid() return self.valid_project end
  function host:selected() return self.selected_project end
  function host:preflight() if not self.ready then return nil,'Not ready' end; return true end
  function host:recording() return self.rec end
  function host:start(s) self.starts=self.starts+1; self.rec=not self.fail_start; s.folder=C.folder(s); return self.rec,'Start failed' end
  function host:stop() self.stops=self.stops+1; if not self.fail_stop then self.rec=false end end
  function host:marker() self.markers=self.markers+1 end
  function host:restore() self.restores=self.restores+1 end
  function host:verify() return self.verified,'Missing audio files' end
  local engine=E.new(state,host)
  return state,host,engine
end
local function tick(e,t) return e:tick(t,t) end

test('strict valid date/time formats',function() eq(C.datetime('261102','1930'),C.datetime('2026-11-02','19:30')) end)
test('reject invalid hour and minute',function() assert(not C.datetime('261102','2561')); assert(not C.datetime('261102','2360')) end)
test('reject impossible calendar dates',function() assert(not C.datetime('260231','1200')); assert(not C.datetime('260229','1200')); assert(C.datetime('280229','1200')) end)
test('reject malformed end rather than converting to open end',function() assert(not C.make(form{finish='123'})) end)
test('blank end is automatically open-ended',function() local s=slot{finish=''}; eq(s.finish,nil) end)
test('overnight requires explicit end date',function() assert(not C.make(form{start='23:30',finish='00:30'})); assert(C.make(form{start='23:30',finish='00:30',enddate='261103'})) end)
test('equal start/end rejected',function() assert(not C.make(form{finish='19:30'})) end)
test('folder naming uses scheduled start and preserves name',function() local s=slot{name='Konzert / Äö 😀',pre='90'}; eq(C.folder(s),'261102 - 1930 Konzert _ Äö 😀'); eq(s.name,'Konzert / Äö 😀') end)
test('folder name cannot traverse directories',function() assert(not C.folder(slot{name='../x\\y\n:*?'}):find('[/\\]')) end)
test('new slots use direct times without hidden margins',function() local s=slot{pre='30',post='60'}; local a,b=C.bounds(s); eq(a,start); eq(b,start+3600) end)
test('overlap rejected atomically with direct times',function() local st=C.new(); assert(C.apply(st,{slot()})); local before=C.serialize(st); assert(not C.apply(st,{slot{start='20:00',finish='21:30'}})); eq(C.serialize(st),before) end)
test('open end conflicts with later slots',function() local st=C.new(); assert(C.apply(st,{slot{finish=''}})); assert(not C.apply(st,{slot{start='21:00',finish='22:00'}})) end)
test('adjacent slots allowed',function() local st=C.new(); assert(C.apply(st,{slot(),slot{start='20:30',finish='21:30'}})) end)
test('edit replaces by stable id without duplicate',function() local st=C.new(); assert(C.apply(st,{slot()})); assert(C.apply(st,{slot{name='Revised'}},st.slots[1].id)); eq(#st.slots,1); eq(st.slots[1].name,'Revised') end)
test('missed slot can be rescheduled after its start passes during editing',function()
  local st,h,e=rig{slot()}
  assert(e:enable(start-10))
  local id=st.slots[1].id
  local draft=slot{start='21:00',finish='22:00'}
  tick(e,start+6)
  eq(st.slots[1].status,'Missed'); eq(h.starts,0)
  assert(C.apply(st,{draft},id))
  eq(#st.slots,1); eq(st.slots[1].status,'Scheduled')
  e:watch(start+7); eq(st.enabled,true)
end)
test('rescheduling missed slot still rejects overlap atomically',function()
  local st=C.new(); assert(C.apply(st,{slot(),slot{start='21:00',finish='22:00'}}))
  st.slots[1].status='Missed'
  local before=C.serialize(st)
  assert(not C.apply(st,{slot{start='21:30',finish='22:30'}},st.slots[1].id))
  eq(C.serialize(st),before)
end)
test('recording history cannot be replaced by editing',function()
  for _,status in ipairs{'Starting','Recording','Completed','Stopped','Partial','Interrupted','Failed','Missed'} do
    local st=C.new(); assert(C.apply(st,{slot()}))
    st.slots[1].status=status; st.slots[1].actual_start=start
    local before=C.serialize(st)
    assert(not C.apply(st,{slot{start='21:00',finish='22:00'}},st.slots[1].id))
    eq(C.serialize(st),before)
  end
end)
test('serialization round trip preserves arbitrary user content',function() local st=C.new(); assert(C.apply(st,{slot{name='Ä\t%\n$ Concert'}})); C.add_log(st,start,'Text\nTabs\t%'); st.root='/recordings A'; local restored=assert(C.deserialize(C.serialize(st))); eq(C.serialize(st),C.serialize(restored)); eq(restored.enabled,false) end)
test('storage never executes Lua',function() assert(not C.deserialize('os.execute("bad")')); assert(not C.deserialize('JG_RECORDING_SCHEDULER\t2\nS\tbad\n')) end)
test('restored recording is interrupted and disarmed',function() local st=C.new(); assert(C.apply(st,{slot()})); st.slots[1].status='Recording'; local restored=assert(C.deserialize(C.serialize(st))); eq(restored.slots[1].status,'Interrupted'); eq(restored.enabled,false) end)
test('disabled scheduler does not start',function() local st,h,e=rig{slot()}; tick(e,start); eq(h.starts,0); eq(st.slots[1].status,'Scheduled') end)
test('enable refuses past start and absent readiness',function() local st,h,e=rig{slot()}; assert(not e:enable(start)); h.ready=false; assert(not e:enable(start-10)) end)
test('scheduled recording starts and verifies completion',function() local st,h,e=rig{slot()}; assert(e:enable(start-10)); tick(e,start); eq(h.starts,1); eq(st.slots[1].status,'Recording'); tick(e,start+3600); eq(h.stops,1); eq(st.slots[1].status,'Completed'); eq(h.restores,1) end)
test('missed slot is never completed',function() local st,h,e=rig{slot()}; assert(e:enable(start-10)); tick(e,start+4000); eq(st.slots[1].status,'Missed'); eq(h.starts,0) end)
test('late wakeup never silently starts',function() local st,h,e=rig{slot()}; assert(e:enable(start-10)); tick(e,start+6); eq(st.slots[1].status,'Missed'); eq(h.starts,0) end)
test('failed start disables further starts and is not recording',function() local st,h,e=rig{slot()}; h.fail_start=true; assert(e:enable(start-10)); tick(e,start); eq(st.slots[1].status,'Failed'); eq(st.enabled,false); eq(e.active,nil) end)
test('unverified files never count as success',function() local st,h,e=rig{slot()}; h.verified=false; assert(e:enable(start-10)); tick(e,start); tick(e,start+3600); eq(st.slots[1].status,'Failed') end)
test('manual stop disarms without restarting the slot',function() local st,h,e=rig{slot{finish=''}}; assert(e:enable(start-10)); tick(e,start); h.rec=false; tick(e,start+1); tick(e,start+2); eq(h.starts,1); eq(st.slots[1].status,'Stopped'); eq(st.enabled,false) end)
test('disabling future starts preserves planned stop',function() local st,h,e=rig{slot()}; assert(e:enable(start-10)); tick(e,start); e:disable(start+5); tick(e,start+3600); eq(h.stops,1); eq(st.slots[1].status,'Completed') end)
test('project tab switch disarms and still stops owned recording',function() local st,h,e=rig{slot()}; assert(e:enable(start-10)); tick(e,start); h.selected_project=false; tick(e,start+1); eq(st.enabled,false); tick(e,start+3600); eq(h.stops,1) end)
test('closed project never receives a stop/start',function() local st,h,e=rig{slot()}; assert(e:enable(start-10)); h.valid_project=false; eq(tick(e,start),false); eq(h.starts,0); eq(h.stops,0) end)
test('legacy plans retain separate mode while new plans use continuous',function()
  eq(C.new().mode,'continuous')
  local old=C.serialize(C.new()):gsub('JG_RECORDING_SCHEDULER\t3','JG_RECORDING_SCHEDULER\t2')
  eq(assert(C.deserialize(old)).mode,'separate')
  eq(assert(C.deserialize(C.serialize(C.new()))).mode,'continuous')
end)
test('continuous adjacent slots never stop or restart at the boundary',function()
  local st,h,e=rig({slot(),slot{start='20:30',finish='21:30',name='Encore'}},'continuous')
  e:watch(start-10); tick(e,start); eq(h.starts,1)
  tick(e,start+3600); eq(h.starts,1); eq(h.stops,0)
  eq(st.slots[1].status,'Captured'); eq(st.slots[2].status,'Recording')
  tick(e,start+7200); eq(h.stops,1)
  eq(st.slots[1].status,'Completed'); eq(st.slots[2].status,'Completed')
  eq(st.slots[1].actual_end,start+3600); eq(st.slots[2].actual_start,start+3600)
end)
test('continuous recording includes gaps and keeps its end after pause',function()
  local st,h,e=rig({slot(),slot{start='22:00',finish='23:00',name='Encore'}},'continuous')
  e:watch(start-10); tick(e,start); tick(e,start+4000)
  eq(h.stops,0); eq(st.slots[2].status,'In session')
  e:disable(start+4001); tick(e,start+9000); eq(h.starts,1); eq(h.stops,0)
  tick(e,start+12600); eq(h.stops,1); eq(st.slots[2].status,'Completed')
end)
test('manual continuous stop preserves completed bands and interrupts future bands',function()
  local st,h,e=rig({slot(),slot{start='22:00',finish='23:00'}},'continuous')
  e:watch(start-10); tick(e,start); tick(e,start+4000); e:stop(start+4001)
  eq(st.slots[1].status,'Completed'); eq(st.slots[2].status,'Interrupted')
  eq(st.slots[2].actual_start,nil); eq(h.stops,1); eq(st.enabled,false)
end)
test('continuous open end and extension do not create an extra recording',function()
  local st,h,e=rig({slot(),slot{start='22:00',finish=''}},'continuous')
  e:watch(start-10); tick(e,start); tick(e,start+9000); eq(h.stops,0); assert(not e:extend(start+9000,300))
  e:stop(start+9001); eq(st.slots[2].status,'Stopped')
  st,h,e=rig({slot()},'continuous'); e:watch(start-10); tick(e,start); assert(e:extend(start+1,300))
  tick(e,start+3600); eq(h.stops,0); tick(e,start+3900); eq(h.stops,1)
end)
test('capture maps and edited region links survive storage',function()
  local st=C.new(); st.captures={{id='capture',wall=start,position=50,folder='/originals',bands={{region=8,start=start,name='Band'}},files={{track='track-guid',name='Mic',path='/originals/mic.wav',position=50,offset=0,length=3600}}}}
  eq(C.serialize(assert(C.deserialize(C.serialize(st)))),C.serialize(st))
end)

test('separate slots stop and restart into their own folders',function() local st,h,e=rig({slot(),slot{start='20:30',finish='21:30',name='Encore'}}); assert(e:enable(start-10)); tick(e,start); tick(e,start+3600); eq(h.starts,2); eq(h.stops,1); assert(st.slots[2].folder~=st.slots[1].folder) end)
test('clock jump disarms and marks active session for review',function() local st,h,e=rig{slot()}; assert(e:enable(start-10)); e:tick(start,100); e:tick(start+100,101); eq(st.enabled,false); assert(st.slots[1].note:find('clock')); e:tick(start+3600,3600); eq(st.slots[1].status,'Partial') end)
test('explicit close stops and marks stopped',function() local st,h,e=rig{slot()}; assert(e:enable(start-10)); tick(e,start); e:stop(start+30,'Closed'); eq(h.stops,1); eq(st.slots[1].status,'Stopped'); eq(st.enabled,false) end)
test('failed stop retains ownership for retry',function() local st,h,e=rig{slot()}; assert(e:enable(start-10)); tick(e,start); h.fail_stop=true; assert(not e:stop(start+30)); assert(e.active); eq(h.rec,true) end)

test('live extension updates end and rejects conflicts',function()
  local st,h,e=rig{slot()}; assert(e:enable(start-10)); tick(e,start); assert(e:extend(start+1,300)); tick(e,start+3600); eq(h.stops,0); tick(e,start+3900); eq(h.stops,1)
  st,h,e=rig{slot(),slot{start='20:30',finish='21:30'}}; assert(e:enable(start-10)); tick(e,start); assert(not e:extend(start+1,300)); eq(st.slots[1].finish,start+3600)
end)
test('DST nonexistent and ambiguous times rejected in Europe/Berlin',function()
  if os.getenv('TZ')=='Europe/Berlin' then assert(not C.datetime('260329','02:30')); assert(not C.datetime('261025','02:30')) end
end)
test('legacy margins become visible direct times without timing loss',function()
  local st=C.new(); local s=slot(); s.pre,s.post=30,45; assert(C.apply(st,{s}))
  local restored=assert(C.deserialize(C.serialize(st))); local v=restored.slots[1]
  eq(v.start,start-30); eq(v.finish,start+3645); eq(v.pre,0); eq(v.post,0)
  eq(C.datetime(os.date('%y%m%d',v.start),os.date('%H:%M:%S',v.start)),v.start)
  eq(C.serialize(assert(C.deserialize(C.serialize(restored)))),C.serialize(restored))
end)
test('automatic watch schedules future slots without a separate enable',function()
  local st,h,e=rig{slot()}; e:watch(start-10); eq(st.enabled,true); tick(e,start); eq(h.starts,1)
end)
test('automatic watch never restarts overdue slots',function()
  local st,h,e=rig{slot()}; e:watch(start+1); eq(st.slots[1].status,'Missed'); tick(e,start+2); eq(h.starts,0)
end)
test('automatic scheduling retains actual-start readiness checks',function()
  local st,h,e=rig{slot()}; h.ready=false; e:watch(start-10); eq(st.enabled,true); tick(e,start); eq(h.starts,0); eq(st.slots[1].status,'Failed')
end)
test('obsolete pause flag does not disable schedules after reopening',function()
  local st=C.new(); local old=C.serialize(st):gsub('\t0\t\n','\t1\t\n',1)
  assert(not C.deserialize(old).paused)
end)
test('timeline reference day is saved once and survives reopening',function()
  local st,h,e=rig{slot()}; e:watch(start-10); tick(e,start)
  eq(st.timeline_origin,C.midnight(start))
  eq(assert(C.deserialize(C.serialize(st))).timeline_origin,st.timeline_origin)
end)
test('trim proposal is non-mutating and confirmed shortening is atomic',function()
  for _,finish in ipairs{'20:30',''} do
    local st=C.new(); assert(C.apply(st,{slot{finish=finish}}))
    local before=C.serialize(st); local draft=slot{start='20:00',finish='21:00'}
    local proposal=assert(C.offer_trim(st,draft)); eq(C.serialize(st),before)
    assert(C.apply(st,{draft},nil,proposal.id)); eq(#st.slots,2)
    eq(st.slots[1].finish,st.slots[2].start); eq(st.slots[2].finish,start+5400)
  end
end)
test('trim never changes equal starts, recorded slots or multiple conflicts',function()
  local st=C.new(); assert(C.apply(st,{slot(),slot{start='21:00',finish='22:00'}}))
  assert(not C.offer_trim(st,slot()))
  local before=C.serialize(st); local draft=slot{start='20:00',finish='21:30'}
  assert(not C.offer_trim(st,draft)); assert(not C.apply(st,{draft},nil,st.slots[1].id)); eq(C.serialize(st),before)
  st.slots[1].status='Recording'; assert(not C.offer_trim(st,slot{start='20:00',finish='20:45'}))
end)
test('blank end ignores unused end date but malformed nonblank time is rejected',function()
  eq(assert(C.make(form{finish='  ',enddate='invalid'})).finish,nil)
  assert(not C.make(form{finish='wrong'}))
  assert(C.make(form{finish='21:00',open=true}).finish)
end)
print(string.format('%d scheduler tests passed.',tests))
