-- @description Track Auto Color
-- @author JG
-- @version 2.0.0
-- @about
--   Context-aware track coloring system using modules.
--   Each module defines folder aliases, a folder darkening percentage,
--   and pattern-to-color rules (with comma-separated pattern aliases).
--   Tracks without a folder context are matched against all modules in order.
--   Auto-colors tracks on changes. ReaImGui GUI for editing.

--------------------------------------------------------------------------------
-- JSON (embedded minimal encoder/decoder)
--------------------------------------------------------------------------------

local json = (function()
  local json = {}

  local encode_value
  local function encode_string(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    s = s:gsub('[\x00-\x1f]', function(c)
      return string.format('\\u%04x', c:byte())
    end)
    return '"' .. s .. '"'
  end

  local function is_array(t)
    if type(t) ~= 'table' then return false end
    local max_idx = 0
    local count = 0
    for k, _ in pairs(t) do
      if type(k) ~= 'number' or k ~= math.floor(k) or k < 1 then return false end
      if k > max_idx then max_idx = k end
      count = count + 1
    end
    return count == max_idx
  end

  local function encode_array(t, indent, level)
    if #t == 0 then return '[]' end
    local parts = {}
    local next_indent = indent and (indent .. '  ') or nil
    for i = 1, #t do
      local v = encode_value(t[i], indent, level + 1)
      if indent then parts[i] = next_indent .. v else parts[i] = v end
    end
    if indent then
      return '[\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. ']'
    else
      return '[' .. table.concat(parts, ',') .. ']'
    end
  end

  local function encode_object(t, indent, level)
    local parts = {}
    local next_indent = indent and (indent .. '  ') or nil
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    for i, k in ipairs(keys) do
      local key = encode_string(tostring(k))
      local val = encode_value(t[k], indent, level + 1)
      if indent then parts[i] = next_indent .. key .. ': ' .. val
      else parts[i] = key .. ':' .. val end
    end
    if #parts == 0 then return '{}' end
    if indent then
      return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}'
    else
      return '{' .. table.concat(parts, ',') .. '}'
    end
  end

  encode_value = function(v, indent, level)
    local vtype = type(v)
    if v == nil then return 'null'
    elseif vtype == 'boolean' then return v and 'true' or 'false'
    elseif vtype == 'number' then
      if v ~= v then return 'null' end
      if v == math.huge or v == -math.huge then return 'null' end
      if v == math.floor(v) and math.abs(v) < 1e15 then return string.format('%.0f', v) end
      return tostring(v)
    elseif vtype == 'string' then return encode_string(v)
    elseif vtype == 'table' then
      if is_array(v) then
        return encode_array(v, indent and (string.rep('  ', level)) or nil, level)
      else
        return encode_object(v, indent and (string.rep('  ', level)) or nil, level)
      end
    else return 'null' end
  end

  function json.encode(value, pretty)
    return encode_value(value, pretty and '' or nil, 0)
  end

  local decode_value
  local function skip_whitespace(s, pos)
    local p = s:find('[^ \t\r\n]', pos)
    return p or #s + 1
  end

  local function decode_string(s, pos)
    if s:byte(pos) ~= 34 then return nil, 'expected string at position ' .. pos end
    local parts = {}
    local i = pos + 1
    while i <= #s do
      local c = s:byte(i)
      if c == 34 then return table.concat(parts), i + 1
      elseif c == 92 then
        i = i + 1
        local esc = s:byte(i)
        if esc == 34 then parts[#parts + 1] = '"'
        elseif esc == 92 then parts[#parts + 1] = '\\'
        elseif esc == 47 then parts[#parts + 1] = '/'
        elseif esc == 98 then parts[#parts + 1] = '\b'
        elseif esc == 102 then parts[#parts + 1] = '\f'
        elseif esc == 110 then parts[#parts + 1] = '\n'
        elseif esc == 114 then parts[#parts + 1] = '\r'
        elseif esc == 116 then parts[#parts + 1] = '\t'
        elseif esc == 117 then
          local hex = s:sub(i + 1, i + 4)
          local code = tonumber(hex, 16)
          if not code then return nil, 'invalid unicode escape at position ' .. i end
          if code < 0x80 then parts[#parts + 1] = string.char(code)
          elseif code < 0x800 then
            parts[#parts + 1] = string.char(0xC0 + math.floor(code / 64), 0x80 + (code % 64))
          else
            parts[#parts + 1] = string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor((code % 4096) / 64), 0x80 + (code % 64))
          end
          i = i + 4
        else parts[#parts + 1] = string.char(esc) end
        i = i + 1
      else
        local j = s:find('[\\"]', i)
        if not j then j = #s + 1 end
        parts[#parts + 1] = s:sub(i, j - 1)
        i = j
      end
    end
    return nil, 'unterminated string'
  end

  local function decode_number(s, pos)
    local num_str = s:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
    if not num_str or #num_str == 0 then return nil, 'invalid number at position ' .. pos end
    local n = tonumber(num_str)
    if not n then return nil, 'invalid number at position ' .. pos end
    return n, pos + #num_str
  end

  local function decode_array(s, pos)
    local arr = {}
    pos = skip_whitespace(s, pos + 1)
    if s:byte(pos) == 93 then return arr, pos + 1 end
    while true do
      local val, next_pos = decode_value(s, pos)
      if val == nil and type(next_pos) == 'string' then return nil, next_pos end
      arr[#arr + 1] = val
      pos = skip_whitespace(s, next_pos)
      local c = s:byte(pos)
      if c == 93 then return arr, pos + 1
      elseif c == 44 then pos = skip_whitespace(s, pos + 1)
      else return nil, 'expected , or ] at position ' .. pos end
    end
  end

  local function decode_object(s, pos)
    local obj = {}
    pos = skip_whitespace(s, pos + 1)
    if s:byte(pos) == 125 then return obj, pos + 1 end
    while true do
      if s:byte(pos) ~= 34 then return nil, 'expected string key at position ' .. pos end
      local key, next_pos = decode_string(s, pos)
      if not key then return nil, next_pos end
      pos = skip_whitespace(s, next_pos)
      if s:byte(pos) ~= 58 then return nil, 'expected : at position ' .. pos end
      pos = skip_whitespace(s, pos + 1)
      local val
      val, next_pos = decode_value(s, pos)
      if val == nil and type(next_pos) == 'string' then return nil, next_pos end
      obj[key] = val
      pos = skip_whitespace(s, next_pos)
      local c = s:byte(pos)
      if c == 125 then return obj, pos + 1
      elseif c == 44 then pos = skip_whitespace(s, pos + 1)
      else return nil, 'expected , or } at position ' .. pos end
    end
  end

  json.null = setmetatable({}, { __tostring = function() return 'null' end })

  decode_value = function(s, pos)
    pos = skip_whitespace(s, pos)
    local c = s:byte(pos)
    if c == 34 then return decode_string(s, pos)
    elseif c == 123 then return decode_object(s, pos)
    elseif c == 91 then return decode_array(s, pos)
    elseif c == 116 then
      if s:sub(pos, pos + 3) == 'true' then return true, pos + 4 end
      return nil, 'invalid value at position ' .. pos
    elseif c == 102 then
      if s:sub(pos, pos + 4) == 'false' then return false, pos + 5 end
      return nil, 'invalid value at position ' .. pos
    elseif c == 110 then
      if s:sub(pos, pos + 3) == 'null' then return json.null, pos + 4 end
      return nil, 'invalid value at position ' .. pos
    elseif c == 45 or (c >= 48 and c <= 57) then return decode_number(s, pos)
    else return nil, 'unexpected character at position ' .. pos .. ': ' .. string.char(c or 0) end
  end

  function json.decode(s)
    if type(s) ~= 'string' then return nil, 'expected string, got ' .. type(s) end
    local value, pos = decode_value(s, 1)
    if value == nil and type(pos) == 'string' then return nil, pos end
    return value
  end

  return json
end)()

--------------------------------------------------------------------------------
-- Constants & ImGui Setup
--------------------------------------------------------------------------------

local VERSION = "2.0.0"
local RESOURCE_PATH = reaper.GetResourcePath()
local DATA_DIR = RESOURCE_PATH .. "/Scripts/JG_TrackColor"
local MODULES_DIR = DATA_DIR .. "/modules"
local MODULE_ORDER_FILE = DATA_DIR .. "/module_order.json"
local SETTINGS_FILE = DATA_DIR .. "/settings.json"

local WINDOW_W, WINDOW_H = 800, 600
local LEFT_PANE_W = 200
local AUTO_COLOR_INTERVAL = 0.3

local ctx = reaper.ImGui_CreateContext('Track Auto Color')
local font = reaper.ImGui_CreateFont('sans-serif', 14)
reaper.ImGui_Attach(ctx, font)

local MATCH_MODES = { "contains", "starts_with", "ends_with", "exact" }
local MATCH_LABELS = { "Contains", "Starts with", "Ends with", "Exact" }

--------------------------------------------------------------------------------
-- Color Helpers
--------------------------------------------------------------------------------

local function hex_to_int(hex)
  hex = hex:gsub('#', '')
  return tonumber(hex, 16) or 0x808080
end

local function int_to_hex(n)
  return string.format("#%02X%02X%02X", (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF)
end

local function hex_to_native(hex)
  hex = hex:gsub('#', '')
  local r = tonumber(hex:sub(1, 2), 16) or 0
  local g = tonumber(hex:sub(3, 4), 16) or 0
  local b = tonumber(hex:sub(5, 6), 16) or 0
  return reaper.ColorToNative(r, g, b) | 0x1000000
end

local function native_to_hex(n)
  local r, g, b = reaper.ColorFromNative(n & 0xFFFFFF)
  return string.format("#%02X%02X%02X", r, g, b)
end

local function darken_color(hex, percent)
  local r_s, g_s, b_s = hex:match("#(%x%x)(%x%x)(%x%x)")
  if not r_s then return hex end
  local r, g, b = tonumber(r_s, 16), tonumber(g_s, 16), tonumber(b_s, 16)
  local factor = 1 - (percent / 100)
  r = math.floor(r * factor)
  g = math.floor(g * factor)
  b = math.floor(b * factor)
  return string.format("#%02X%02X%02X", r, g, b)
end

--------------------------------------------------------------------------------
-- Data Layer
--------------------------------------------------------------------------------

local state = {
  modules = {},
  module_order = {},
  settings = { uppercase_darken_percent = 30 },
  dirty = false,
  settings_dirty = false,
  selected_module_idx = 1,
  status_msg = "",
  status_time = 0,
  last_fingerprint = "",
  auto_color = true,
}

local function set_status(msg)
  state.status_msg = msg
  state.status_time = reaper.time_precise()
end

local function ensure_data_dir()
  reaper.RecursiveCreateDirectory(DATA_DIR, 0)
  reaper.RecursiveCreateDirectory(MODULES_DIR, 0)
end

local function slugify(name)
  local s = name:lower()
  s = s:gsub('[^%w%-_ ]', '')
  s = s:gsub('%s+', '_')
  s = s:gsub('_+', '_')
  s = s:gsub('^_', ''):gsub('_$', '')
  if s == '' then s = 'module' end
  return s
end

local function load_json_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local content = f:read('*a')
  f:close()
  if not content or content == '' then return nil end
  local ok, result = pcall(json.decode, content)
  if ok then return result end
  return nil
end

local function save_json_file(path, data)
  local ok, encoded = pcall(json.encode, data, true)
  if not ok then return false end
  local f = io.open(path, 'w')
  if not f then return false end
  f:write(encoded)
  f:close()
  return true
end

local function load_settings()
  local data = load_json_file(SETTINGS_FILE)
  if data then
    state.settings.uppercase_darken_percent = data.uppercase_darken_percent or 30
  end
end

local function save_settings()
  save_json_file(SETTINGS_FILE, state.settings)
  state.settings_dirty = false
end

local function load_module_order()
  local data = load_json_file(MODULE_ORDER_FILE)
  if data and type(data) == 'table' then
    state.module_order = data
  else
    state.module_order = {}
  end
end

local function save_module_order()
  local order = {}
  for _, mod in ipairs(state.modules) do
    order[#order + 1] = slugify(mod.name) .. ".json"
  end
  save_json_file(MODULE_ORDER_FILE, order)
end

local function load_module(filename)
  local path = MODULES_DIR .. "/" .. filename
  local data = load_json_file(path)
  if not data then return nil end
  data.name = data.name or filename:gsub('%.json$', '')
  data.folder_aliases = data.folder_aliases or {}
  data.folder_darken_percent = data.folder_darken_percent or 10
  data.rules = data.rules or {}
  return data
end

local function save_module(mod)
  local slug = slugify(mod.name)
  local path = MODULES_DIR .. "/" .. slug .. ".json"
  save_json_file(path, mod)
end

local function delete_module_file(mod)
  local slug = slugify(mod.name)
  local path = MODULES_DIR .. "/" .. slug .. ".json"
  os.remove(path)
end

local function load_all_modules()
  local modules = {}
  local loaded_files = {}

  for _, filename in ipairs(state.module_order) do
    local mod = load_module(filename)
    if mod then
      modules[#modules + 1] = mod
      loaded_files[filename] = true
    end
  end

  local unordered = {}
  local i = 0
  while true do
    local file = reaper.EnumerateFiles(MODULES_DIR, i)
    if not file then break end
    if file:match('%.json$') and not loaded_files[file] then
      unordered[#unordered + 1] = file
    end
    i = i + 1
  end
  table.sort(unordered)
  for _, filename in ipairs(unordered) do
    local mod = load_module(filename)
    if mod then modules[#modules + 1] = mod end
  end

  state.modules = modules
end

local function load_all_data()
  load_module_order()
  load_all_modules()
  load_settings()
end

local function save_all_data()
  save_module_order()
  for _, mod in ipairs(state.modules) do
    save_module(mod)
  end
  save_settings()
  state.dirty = false
end

--------------------------------------------------------------------------------
-- Color Engine
--------------------------------------------------------------------------------

local function get_track_name(track)
  local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  return name
end

local function is_folder_track(track)
  return reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") == 1
end

local function build_alias_lookup()
  local lookup = {}
  for i, mod in ipairs(state.modules) do
    for _, alias in ipairs(mod.folder_aliases) do
      local key = alias:upper()
      if not lookup[key] then lookup[key] = {} end
      lookup[key][#lookup[key] + 1] = { idx = i, mod = mod }
    end
  end
  return lookup
end

-- Walk up parent chain; innermost folder alias match wins, lowest module index breaks ties
local function find_module_for_track(track, alias_lookup)
  local current = track
  while true do
    local parent = reaper.GetParentTrack(current)
    if not parent then return nil end
    local parent_name = get_track_name(parent):upper()
    local candidates = alias_lookup[parent_name]
    if candidates and #candidates > 0 then
      local best = candidates[1]
      for _, cand in ipairs(candidates) do
        if cand.idx < best.idx then best = cand end
      end
      return best.mod
    end
    current = parent
  end
end

-- Check if a track's own name matches a module alias (for folder darkening)
local function find_module_as_folder(track_name, alias_lookup)
  local key = track_name:upper()
  local candidates = alias_lookup[key]
  if not candidates or #candidates == 0 then return nil end
  local best = candidates[1]
  for _, cand in ipairs(candidates) do
    if cand.idx < best.idx then best = cand end
  end
  return best.mod
end

local function is_all_uppercase(name)
  local letters = name:gsub("[^%a]", "")
  return #letters > 0 and letters == letters:upper()
end

-- Match track name against rule; pattern field supports comma-separated aliases
local function match_rule(track_name, rule)
  local name = track_name:upper()
  for pat in rule.pattern:gmatch('[^,]+') do
    pat = pat:match('^%s*(.-)%s*$'):upper()
    if pat ~= '' then
      local matched = false
      if rule.match_mode == "contains" then
        matched = string.find(name, pat, 1, true) ~= nil
      elseif rule.match_mode == "starts_with" then
        matched = name:sub(1, #pat) == pat
      elseif rule.match_mode == "ends_with" then
        matched = name:sub(-#pat) == pat
      elseif rule.match_mode == "exact" then
        matched = name == pat
      end
      if matched then return true end
    end
  end
  return false
end

local function build_fingerprint()
  local parts = {}
  local track_count = reaper.CountTracks(0)
  parts[1] = tostring(track_count)
  for i = 0, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    local name = get_track_name(track)
    local depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
    parts[#parts + 1] = name .. "|" .. depth
  end
  return table.concat(parts, "\n")
end

local function run_engine()
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local alias_lookup = build_alias_lookup()
  local track_count = reaper.CountTracks(0)
  local colored = 0
  local skipped_user = 0
  local no_match = 0

  for i = 0, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    local track_name = get_track_name(track)
    local is_folder = is_folder_track(track)

    -- User color protection
    local current_color = reaper.GetTrackColor(track)
    local _, last_applied_str = reaper.GetSetMediaTrackInfo_String(
      track, "P_EXT:JG_AutoColor_last", "", false)
    local last_applied = tonumber(last_applied_str) or 0

    if current_color ~= 0 and current_color ~= last_applied then
      skipped_user = skipped_user + 1
    else
      local mod = find_module_for_track(track, alias_lookup)
      local resolved_color = nil

      if mod then
        -- In module context: match against that module's rules only
        for _, rule in ipairs(mod.rules) do
          if match_rule(track_name, rule) then
            resolved_color = rule.color
            break
          end
        end
      else
        -- No module context: iterate all modules' rules in order
        for _, m in ipairs(state.modules) do
          for _, rule in ipairs(m.rules) do
            if match_rule(track_name, rule) then
              resolved_color = rule.color
              break
            end
          end
          if resolved_color then break end
        end
      end

      -- Inherit from parent (use undarkened base color stored in P_EXT)
      if not resolved_color then
        local parent = reaper.GetParentTrack(track)
        while parent do
          local _, parent_base = reaper.GetSetMediaTrackInfo_String(
            parent, "P_EXT:JG_AutoColor_base", "", false)
          if parent_base and parent_base ~= "" then
            resolved_color = parent_base
            break
          end
          local pc = reaper.GetTrackColor(parent)
          if pc ~= 0 then
            resolved_color = native_to_hex(pc)
            break
          end
          parent = reaper.GetParentTrack(parent)
        end
      end

      if resolved_color then
        -- Store base (undarkened) color for children to inherit
        reaper.GetSetMediaTrackInfo_String(
          track, "P_EXT:JG_AutoColor_base", resolved_color, true)

        -- Module folder darkening: if this folder IS a module alias, darken it
        if is_folder then
          local folder_mod = find_module_as_folder(track_name, alias_lookup)
          if folder_mod and folder_mod.folder_darken_percent > 0 then
            resolved_color = darken_color(resolved_color, folder_mod.folder_darken_percent)
          end
        end

        -- Uppercase darkening
        local darken = state.settings.uppercase_darken_percent
        if darken > 0 and is_all_uppercase(track_name) then
          resolved_color = darken_color(resolved_color, darken)
        end

        local native = hex_to_native(resolved_color)
        reaper.SetTrackColor(track, native)
        reaper.GetSetMediaTrackInfo_String(
          track, "P_EXT:JG_AutoColor_last", tostring(native), true)
        colored = colored + 1
      else
        no_match = no_match + 1
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Track Auto Color", -1)

  local parts = { colored .. " colored" }
  if skipped_user > 0 then parts[#parts + 1] = skipped_user .. " skipped (manual)" end
  if no_match > 0 then parts[#parts + 1] = no_match .. " no match" end
  set_status(table.concat(parts, ", "))
end

local last_auto_check = 0
local function auto_color_check()
  local now = reaper.time_precise()
  if now - last_auto_check < AUTO_COLOR_INTERVAL then return end
  last_auto_check = now
  if not state.auto_color then return end
  local fp = build_fingerprint()
  if fp ~= state.last_fingerprint then
    state.last_fingerprint = fp
    run_engine()
  end
end

--------------------------------------------------------------------------------
-- GUI
--------------------------------------------------------------------------------

local function new_rule()
  return { pattern = "", match_mode = "contains", color = "#808080" }
end

local function match_mode_index(mode)
  for i, m in ipairs(MATCH_MODES) do
    if m == mode then return i end
  end
  return 1
end

local function draw_rule_row(rules, idx, prefix)
  local rule = rules[idx]
  local deleted = false

  reaper.ImGui_PushID(ctx, prefix .. "_" .. idx)

  -- Pattern (wide for comma-separated aliases)
  reaper.ImGui_SetNextItemWidth(ctx, 220)
  local changed, new_pat = reaper.ImGui_InputText(ctx, '##pat', rule.pattern)
  if changed then rule.pattern = new_pat; state.dirty = true end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Comma-separated patterns, e.g. "Violin, Vln, Vl"')
  end

  reaper.ImGui_SameLine(ctx)

  -- Match mode
  reaper.ImGui_SetNextItemWidth(ctx, 100)
  local mode_idx = match_mode_index(rule.match_mode)
  if reaper.ImGui_BeginCombo(ctx, '##mode', MATCH_LABELS[mode_idx]) then
    for i, label in ipairs(MATCH_LABELS) do
      if reaper.ImGui_Selectable(ctx, label, i == mode_idx) then
        rule.match_mode = MATCH_MODES[i]
        state.dirty = true
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  reaper.ImGui_SameLine(ctx)

  -- Color
  local col = hex_to_int(rule.color)
  local col_changed, new_col = reaper.ImGui_ColorEdit3(ctx, '##col', col,
    reaper.ImGui_ColorEditFlags_NoInputs())
  if col_changed then
    rule.color = int_to_hex(new_col)
    state.dirty = true
  end

  reaper.ImGui_SameLine(ctx)

  -- Move up
  if idx > 1 then
    if reaper.ImGui_SmallButton(ctx, '^##up') then
      rules[idx], rules[idx - 1] = rules[idx - 1], rules[idx]
      state.dirty = true
    end
  else
    reaper.ImGui_InvisibleButton(ctx, '##up_ph', 20, 1)
  end

  reaper.ImGui_SameLine(ctx)

  -- Move down
  if idx < #rules then
    if reaper.ImGui_SmallButton(ctx, 'v##dn') then
      rules[idx], rules[idx + 1] = rules[idx + 1], rules[idx]
      state.dirty = true
    end
  else
    reaper.ImGui_InvisibleButton(ctx, '##dn_ph', 20, 1)
  end

  reaper.ImGui_SameLine(ctx)

  -- Delete
  if reaper.ImGui_SmallButton(ctx, 'X##del') then
    deleted = true
    state.dirty = true
  end

  reaper.ImGui_PopID(ctx)
  return deleted
end

local function get_alias_conflicts()
  local alias_mods = {}
  for _, mod in ipairs(state.modules) do
    for _, alias in ipairs(mod.folder_aliases) do
      local key = alias:upper()
      if not alias_mods[key] then alias_mods[key] = {} end
      alias_mods[key][#alias_mods[key] + 1] = mod.name
    end
  end
  local conflicts = {}
  for alias, mods in pairs(alias_mods) do
    if #mods > 1 then conflicts[alias] = mods end
  end
  return conflicts
end

local function parse_comma_list(str)
  local result = {}
  for item in str:gmatch('[^,]+') do
    local trimmed = item:match('^%s*(.-)%s*$')
    if trimmed ~= '' then result[#result + 1] = trimmed end
  end
  return result
end

local function join_comma_list(tbl)
  return table.concat(tbl, ", ")
end

local function draw_top_bar()
  -- Auto-color toggle
  local ac_changed, ac_val = reaper.ImGui_Checkbox(ctx, 'Auto', state.auto_color)
  if ac_changed then state.auto_color = ac_val end

  reaper.ImGui_SameLine(ctx)

  -- Manual trigger
  if reaper.ImGui_Button(ctx, 'Color now', 80, 24) then
    state.last_fingerprint = ""
    run_engine()
  end

  reaper.ImGui_SameLine(ctx)

  -- Uppercase darken slider
  reaper.ImGui_SetNextItemWidth(ctx, 100)
  local dk_chg, dk_val = reaper.ImGui_SliderInt(ctx, 'UC darken %',
    state.settings.uppercase_darken_percent, 0, 80)
  if dk_chg then
    state.settings.uppercase_darken_percent = dk_val
    state.settings_dirty = true
    state.last_fingerprint = ""
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Darken UPPERCASE track names by this percentage')
  end

  reaper.ImGui_SameLine(ctx)

  -- Export
  if reaper.ImGui_Button(ctx, 'Export', 55, 24) then
    local has_js = reaper.APIExists('JS_Dialog_BrowseForSaveFile')
    local export_path

    if has_js then
      local retval, path = reaper.JS_Dialog_BrowseForSaveFile(
        'Export Track Auto Color', '', 'track_auto_color_export.json', 'JSON Files\0*.json\0')
      if retval == 1 and path ~= '' then export_path = path end
    else
      local retval, path = reaper.GetUserInputs(
        'Export path', 1, 'File path:', DATA_DIR .. '/export.json')
      if retval and path ~= '' then export_path = path end
    end

    if export_path then
      local export_data = {
        modules = state.modules,
        module_order = {},
        settings = state.settings,
      }
      for _, mod in ipairs(state.modules) do
        export_data.module_order[#export_data.module_order + 1] = slugify(mod.name) .. ".json"
      end
      if save_json_file(export_path, export_data) then
        set_status("Export successful")
      else
        set_status("Export failed!")
      end
    end
  end

  reaper.ImGui_SameLine(ctx)

  -- Import
  if reaper.ImGui_Button(ctx, 'Import', 55, 24) then
    local has_js = reaper.APIExists('JS_Dialog_BrowseForOpenFiles')
    local import_path

    if has_js then
      local retval, path = reaper.JS_Dialog_BrowseForOpenFiles(
        'Import Track Auto Color', '', '', 'JSON Files\0*.json\0', false)
      if retval == 1 and path ~= '' then import_path = path end
    else
      local retval, path = reaper.GetUserInputs(
        'Import path', 1, 'File path:', '')
      if retval and path ~= '' then import_path = path end
    end

    if import_path then
      local data = load_json_file(import_path)
      if data then
        for _, mod in ipairs(state.modules) do
          delete_module_file(mod)
        end
        if data.modules then state.modules = data.modules end
        if data.module_order then state.module_order = data.module_order end
        if data.settings then state.settings = data.settings end
        state.selected_module_idx = 1
        state.dirty = true
        save_all_data()
        state.last_fingerprint = ""
        set_status("Import successful!")
      else
        set_status("Import failed - invalid file")
      end
    end
  end

  reaper.ImGui_SameLine(ctx)

  -- Status message (auto-clears after 5s)
  if state.status_msg ~= "" then
    if reaper.time_precise() - state.status_time > 5 then
      state.status_msg = ""
    else
      reaper.ImGui_Text(ctx, state.status_msg)
    end
  end
end

local function draw_modules()
  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local conflicts = get_alias_conflicts()
  local btn_h = 30
  local right_w = avail_w - LEFT_PANE_W - 16

  -- Left pane
  if reaper.ImGui_BeginChild(ctx, '##mod_left', LEFT_PANE_W, avail_h) then
    if reaper.ImGui_BeginChild(ctx, '##mod_list', LEFT_PANE_W, avail_h - btn_h - 8,
        reaper.ImGui_ChildFlags_Borders()) then
      for i, mod in ipairs(state.modules) do
        local has_conflict = false
        for _, alias in ipairs(mod.folder_aliases) do
          if conflicts[alias:upper()] then has_conflict = true; break end
        end

        local label = mod.name
        if has_conflict then label = "! " .. label end

        if reaper.ImGui_Selectable(ctx, label .. '##mod' .. i, i == state.selected_module_idx) then
          state.selected_module_idx = i
        end
      end
      reaper.ImGui_EndChild(ctx)
    end

    -- Module buttons
    if reaper.ImGui_Button(ctx, '+##newmod') then
      state.modules[#state.modules + 1] = {
        name = "New Module",
        folder_aliases = {},
        folder_darken_percent = 10,
        rules = {},
      }
      state.selected_module_idx = #state.modules
      state.dirty = true
    end
    reaper.ImGui_SameLine(ctx)

    if reaper.ImGui_Button(ctx, 'Dup.##dupmod') and #state.modules > 0 then
      local src = state.modules[state.selected_module_idx]
      if src then
        local copy = json.decode(json.encode(src))
        copy.name = src.name .. " (Copy)"
        state.modules[#state.modules + 1] = copy
        state.selected_module_idx = #state.modules
        state.dirty = true
      end
    end
    reaper.ImGui_SameLine(ctx)

    if reaper.ImGui_Button(ctx, 'Del.##delmod') and #state.modules > 0 then
      local mod = state.modules[state.selected_module_idx]
      if mod then
        delete_module_file(mod)
        table.remove(state.modules, state.selected_module_idx)
        if state.selected_module_idx > #state.modules then
          state.selected_module_idx = math.max(1, #state.modules)
        end
        state.dirty = true
      end
    end
    reaper.ImGui_SameLine(ctx)

    if reaper.ImGui_Button(ctx, '^##modup') and state.selected_module_idx > 1 then
      local idx = state.selected_module_idx
      state.modules[idx], state.modules[idx - 1] = state.modules[idx - 1], state.modules[idx]
      state.selected_module_idx = idx - 1
      state.dirty = true
    end
    reaper.ImGui_SameLine(ctx)

    if reaper.ImGui_Button(ctx, 'v##moddn') and state.selected_module_idx < #state.modules then
      local idx = state.selected_module_idx
      state.modules[idx], state.modules[idx + 1] = state.modules[idx + 1], state.modules[idx]
      state.selected_module_idx = idx + 1
      state.dirty = true
    end

    reaper.ImGui_EndChild(ctx)
  end

  -- Right pane
  reaper.ImGui_SameLine(ctx)

  if reaper.ImGui_BeginChild(ctx, '##mod_editor', right_w, avail_h,
      reaper.ImGui_ChildFlags_Borders()) then
    local mod = state.modules[state.selected_module_idx]
    if mod then
      -- Name
      reaper.ImGui_Text(ctx, 'Name:')
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, right_w - 80)
      local name_changed, new_name = reaper.ImGui_InputText(ctx, '##modname', mod.name)
      if name_changed then
        delete_module_file(mod)
        mod.name = new_name
        state.dirty = true
      end

      -- Folder aliases
      reaper.ImGui_Text(ctx, 'Folder aliases:')
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, 'Folder names that activate this module (case-insensitive, comma-separated)')
      end
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, right_w - 130)
      local alias_str = join_comma_list(mod.folder_aliases)
      local alias_changed, new_alias = reaper.ImGui_InputText(ctx, '##aliases', alias_str)
      if alias_changed then
        mod.folder_aliases = parse_comma_list(new_alias)
        state.dirty = true
      end

      -- Alias conflict warnings
      for _, alias in ipairs(mod.folder_aliases) do
        local key = alias:upper()
        if conflicts[key] then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x4444FFFF)
          reaper.ImGui_Text(ctx, 'Alias conflict: "' .. alias .. '" also in: '
            .. table.concat(conflicts[key], ', '))
          reaper.ImGui_PopStyleColor(ctx)
        end
      end

      -- Folder darken slider
      reaper.ImGui_Text(ctx, 'Folder darken:')
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
          'Darken the module folder track by this percentage.\nChildren inherit the undarkened color.')
      end
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, 120)
      local fd_changed, fd_val = reaper.ImGui_SliderInt(ctx, '##fdarken',
        mod.folder_darken_percent, 0, 50)
      if fd_changed then
        mod.folder_darken_percent = fd_val
        state.dirty = true
      end

      reaper.ImGui_Separator(ctx)

      -- Rules header
      reaper.ImGui_Text(ctx, 'Pattern')
      reaper.ImGui_SameLine(ctx, 230)
      reaper.ImGui_Text(ctx, 'Match')
      reaper.ImGui_SameLine(ctx, 340)
      reaper.ImGui_Text(ctx, 'Color')
      reaper.ImGui_Separator(ctx)

      local to_delete = nil
      for i = 1, #mod.rules do
        if draw_rule_row(mod.rules, i, "mr" .. state.selected_module_idx) then
          to_delete = i
        end
      end
      if to_delete then table.remove(mod.rules, to_delete) end

      if reaper.ImGui_Button(ctx, '+ Add rule##mr') then
        mod.rules[#mod.rules + 1] = new_rule()
        state.dirty = true
      end
    else
      reaper.ImGui_Text(ctx, 'No module selected')
    end
    reaper.ImGui_EndChild(ctx)
  end
end

--------------------------------------------------------------------------------
-- Main Loop
--------------------------------------------------------------------------------

local function loop()
  reaper.ImGui_PushFont(ctx, font, 14)
  reaper.ImGui_SetNextWindowSize(ctx, WINDOW_W, WINDOW_H, reaper.ImGui_Cond_FirstUseEver())

  local visible, open = reaper.ImGui_Begin(ctx, 'Track Auto Color v' .. VERSION, true)

  if visible then
    draw_top_bar()
    reaper.ImGui_Separator(ctx)
    draw_modules()
  end

  reaper.ImGui_End(ctx)
  reaper.ImGui_PopFont(ctx)

  auto_color_check()

  if state.dirty then
    save_all_data()
    state.last_fingerprint = ""
  end

  if state.settings_dirty then
    save_settings()
  end

  if open then
    reaper.defer(loop)
  end
end

-- Entry point
ensure_data_dir()
load_all_data()
loop()
