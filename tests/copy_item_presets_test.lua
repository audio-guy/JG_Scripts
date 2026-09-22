-- Run from the repository root: lua tests/copy_item_presets_test.lua
local f = assert(io.open("Tools/JG_Copy_Item_Properties.lua"))
local source = assert(f:read("*a"):match("^(.-)\nloadPrefs%(%)"))
f:close()
local storage = {}
local function session()
  reaper = {
    ImGui_CreateContext = function() end,
    GetExtState = function(_, key) return storage[key] or "" end,
    SetExtState = function(_, key, value, persist)
      assert(persist and not value:find("[\r\n]"))
      storage[key] = value
    end,
  }
  return assert(load(source .. "\n" .. [[
    loadPrefs()
    loadPresets()
    return {
      opt = opt, create = createPreset, update = updatePreset,
      rename = renamePreset, delete = deletePreset, select = selectPreset,
      modified = presetModified, savePrefs = savePrefs,
      list = function() return presets end,
      active = function() return activePreset end,
    }
  ]]))()
end

local s = session()
assert(#s.list() == 0 and not s.active())
assert(not s.create("   "))
assert(not s.create("bad\nname"))
assert(not s.create("bad##name"))
for key in pairs(s.opt) do s.opt[key] = false end
s.opt.fades = true
local name = "Fäden | FX; 50%, = 'Studio'"
local first = assert(s.create("  " .. name .. "  "))
assert(first.name == name and first.values.fades and not first.values.cuts)
assert(not s.create(name:upper()), "Duplicate name accepted")
s.opt.cuts = true
assert(s.modified() and not first.values.cuts, "Editing checkboxes overwrote the preset")
s.select(first)
assert(not s.opt.cuts and not s.modified(), "Clicking did not restore all options")
s.opt.env = true
s.update()
assert(first.values.env and not s.modified())
local second = assert(s.create("Second"))
s.opt.env = false
s.update()
assert(first.values.env and not second.values.env, "Presets share option tables")
assert(not s.rename(name), "Rename overwrote another preset")
assert(s.rename("Renamed").name == "Renamed")
s.opt.mute = true
s.savePrefs()

-- Restart must preserve presets and unsaved checkbox edits independently.
s = session()
assert(#s.list() == 2 and s.active().name == "Renamed")
assert(s.opt.mute and s.modified())
s.select(s.list()[1])
assert(s.opt.env and s.opt.fades and not s.opt.cuts and not s.opt.mute)
assert(s.list()[1].name == name, "UTF-8/delimiter round trip failed")
s.delete()
assert(#s.list() == 1 and not s.active() and s.opt.env)
s = session()
assert(#s.list() == 1 and s.list()[1].name == "Renamed" and not s.active())
s.select(s.list()[1])
s.delete()
s = session()
assert(#s.list() == 0, "Deleting the final preset did not persist")

-- Older presets do not enable newly introduced options by default.
storage.presets = "v1;4F6C64|fades=1,unknown=1"
s = session()
s.select(s.list()[1])
assert(s.opt.fades and not s.opt.fx and s.opt.unknown == nil)
storage.presets = "v1;invalid;GG|cuts=1;1|cuts=1"
s = session()
assert(#s.list() == 0)
print("PASS: named presets create/load/update/rename/delete, persist across sessions,")
print("      preserve UTF-8, reject duplicates, and isolate unsaved checkbox changes")
