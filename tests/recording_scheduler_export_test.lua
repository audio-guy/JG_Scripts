-- Generated PCM fixtures exercise real byte exports without REAPER or audio hardware.
local M=assert(loadfile('Tools/JG_Recording_Scheduler.lua'))('__test')
local W,C,H=M.Wave,M.Core,M.Host
local root=os.tmpname(); os.remove(root); assert(os.execute('mkdir -p '..string.format('%q',root)))
local paths={}; local tests=0
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function test(name,fn) local ok,err=pcall(fn); assert(ok,name..': '..tostring(err)); tests=tests+1; print('PASS '..name) end
local function path(name) local p=root..'/'..name; paths[p]=true; return p end
local fmt=string.pack('<I2I2I4I4I2I2',1,1,8,16,2,16)
local function wav(name,bytes,format)
  local p=path(name); local f=assert(io.open(p,'wb'))
  local job={format=format or fmt,code=1,align=2,bytes=#bytes,samples=#bytes//2}
  assert(f:write(W.header(job),bytes)); assert(f:close()); return p
end
local function read(p) local f=assert(io.open(p,'rb')); local v=f:read('*a'); f:close(); return v end
local function finish(task)
  while coroutine.status(task.thread)~='dead' do local ok,err=coroutine.resume(task.thread); if not ok then task:close(); error(err) end end
  task:close()
end
local samples={}; for i=1,24 do samples[i]=string.pack('<i2',i*100) end
local audio=table.concat(samples)
local one=wav('one.wav',audio:sub(1,16)); local two=wav('two.wav',audio:sub(17))
local files={{track='A',name='Mic',path=one,position=10,offset=0,length=1},{track='A',name='Mic',path=two,position=11,offset=0,length=2}}
test('sample-exact cut joins split source files without gain or gaps',function()
  local jobs=W.plan(files,10.5,12.5); eq(#jobs,1); jobs[1].path=path('cut.wav')
  finish(W.writer(jobs)); local info=assert(W.inspect(jobs[1].path)); eq(info.samples,16)
  eq(read(jobs[1].path):sub(info.data+1,info.data+info.bytes),audio:sub(9,40))
  eq(read(one):sub(-16),audio:sub(1,16))
end)
test('source offsets and stereo sample frames are preserved',function()
  local stereo=string.pack('<I2I2I4I4I2I2',1,2,8,32,4,16)
  local p=wav('stereo.wav',audio,stereo)
  local jobs=W.plan({{track='S',name='Stereo',path=p,position=0,offset=0.25,length=1}},0,1)
  jobs[1].path=path('stereo-cut.wav'); finish(W.writer(jobs)); local info=assert(W.inspect(jobs[1].path))
  eq(info.align,4); eq(read(jobs[1].path):sub(info.data+1,info.data+info.bytes),audio:sub(9,40))
end)
test('missing tracks, gaps and out-of-range regions fail before export',function()
  assert(not pcall(W.plan,files,9,12))
  local gapped={files[1],{track='A',name='Mic',path=two,position=11.1,offset=0,length=2}}
  assert(not pcall(W.plan,gapped,10,12))
  local missing={files[1],files[2],{track='B',name='Other',path=one,position=100,offset=0,length=1}}
  assert(not pcall(W.plan,missing,10,12))
end)
test('float WAV bytes and odd-sized PCM data retain format',function()
  local floatfmt=string.pack('<I2I2I4I4I2I2',3,1,8,32,4,32)
  local f=path('float.wav'); local bytes=string.pack('<ffff',0.25,-0.5,1.25,0)
  local out=assert(io.open(f,'wb')); out:write(W.header{format=floatfmt,code=3,bytes=16,samples=4},bytes); out:close()
  local jobs=W.plan({{track='F',name='Float',path=f,position=0,offset=0,length=0.5}},0,0.5)
  jobs[1].path=path('float-cut.wav'); finish(W.writer(jobs)); local info=assert(W.inspect(jobs[1].path)); eq(info.code,3)
  eq(read(jobs[1].path):sub(info.data+1,info.data+info.bytes),bytes)
  local pcm8=string.pack('<I2I2I4I4I2I2',1,1,8,8,1,8)
  local data='\128\129\130'; local p=path('odd.wav'); out=assert(io.open(p,'wb'))
  out:write(W.header{format=pcm8,code=1,bytes=3,samples=3},data,'\0'); out:close()
  jobs=W.plan({{track='8',name='8bit',path=p,position=0,offset=0,length=3/8}},0,3/8)
  jobs[1].path=path('odd-cut.wav'); finish(W.writer(jobs)); info=assert(W.inspect(jobs[1].path)); eq(info.bytes,3); eq(#read(jobs[1].path)%2,0)
end)
test('RF64 sizes are parsed and large exports receive RF64 headers',function()
  local p=path('rf64.wav'); local body='fmt '..string.pack('<I4',#fmt)..fmt..'data'..string.pack('<I4',0xffffffff)..audio
  local f=assert(io.open(p,'wb')); f:write('RF64'..string.pack('<I4',0xffffffff)..'WAVEds64'..string.pack('<I4I8I8I8I4',28,4+36+#body,#audio,24,0)..body); f:close()
  eq(assert(W.inspect(p)).samples,24)
  eq(W.header{format=fmt,code=1,bytes=0x100000000,samples=0x80000000}:sub(1,4),'RF64')
end)
test('unsupported and truncated audio is rejected',function()
  local p=path('broken.wav'); local f=assert(io.open(p,'wb')); f:write('not a wave file'); f:close(); assert(not W.inspect(p))
  f=assert(io.open(p,'wb')); f:write(W.header{format=fmt,code=1,bytes=100,samples=50},'short'); f:close(); assert(not W.inspect(p))
end)
test('cancel removes only partial export and never overwrites an existing file',function()
  local jobs=W.plan(files,10,12); jobs[1].path=path('cancel.wav')
  local task=W.writer(jobs); assert(coroutine.resume(task.thread)); task:close()
  assert(not io.open(jobs[1].path..'.partial','rb')); assert(not io.open(jobs[1].path,'rb'))
  local f=assert(io.open(jobs[1].path,'wb')); f:write('existing'); f:close()
  task=W.writer(jobs); assert(not coroutine.resume(task.thread)); task:close(); eq(read(jobs[1].path),'existing')
end)
test('export uses edited region boundaries and names after persistence',function()
  local regions={{id=5,position=10.5,finish=12.5,name='New / Band'}}
  local api={GetPlayStateEx=function() return 0 end,GetProjectPathEx=function() return root end,genGuid=function() return '{export}' end,
    EnumProjectMarkers3=function(_,i) local v=regions[i+1]; if not v then return 0 end; return 1,true,v.position,v.finish,v.name,v.id,0 end}
  local h=H.new(api,{}); h.project_file=function() return root..'/session.rpp' end
  local st=C.new(); st.root=root
  st.captures={{id='capture',wall=assert(C.datetime('261103','19:00')),position=10,folder=root,bands={{region=5,start=0,name='Original Band'}},files=files}}
  st=assert(C.deserialize(C.serialize(st)))
  local plan=assert(h:export_plan(st)); eq(plan.bands,1); eq(plan.jobs[1].samples,16)
  assert(plan.jobs[1].path:find('261103 %- 1900 New _ Band/'))
  regions[1].position=11; regions[1].finish=12; plan=assert(h:export_plan(st)); eq(plan.jobs[1].samples,8)
  regions={}; assert(not h:export_plan(st))
end)
test('selected bands omit unavailable regions without changing the recording plan',function()
  local api={GetPlayStateEx=function() return 0 end,GetProjectPathEx=function() return root end,genGuid=function() return '{export}' end,
    EnumProjectMarkers3=function(_,i) if i>0 then return 0 end; return 1,true,10,11,'Band',1,0 end}
  local h=H.new(api,{}); local st=C.new(); st.captures={{id='c',wall=0,position=10,folder=root,bands={{region=1,start=0,name='Band'},{region=2,start=1,name='Missing'}},files=files}}
  local before=C.serialize(st); assert(not h:export_plan(st)); local plan=assert(h:export_plan(st,{['c:1']=true}))
  eq(plan.bands,1); eq(C.serialize(st),before)
end)
for p in pairs(paths) do os.remove(p); os.remove(p..'.partial') end
os.remove(root)
print(tests..' export tests passed.')
