-- Minimal JSON encoder/decoder for Lua
-- Handles objects, arrays, strings, numbers, booleans, null
-- Returns a table with encode() and decode() functions

local json = {}

----------------------------------------------------------------
-- Encode
----------------------------------------------------------------

local encode_value -- forward declaration

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
    if type(k) ~= 'number' or k ~= math.floor(k) or k < 1 then
      return false
    end
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
    if indent then
      parts[i] = next_indent .. v
    else
      parts[i] = v
    end
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
  -- Sort keys for deterministic output
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for i, k in ipairs(keys) do
    local key = encode_string(tostring(k))
    local val = encode_value(t[k], indent, level + 1)
    if indent then
      parts[i] = next_indent .. key .. ': ' .. val
    else
      parts[i] = key .. ':' .. val
    end
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
  if v == nil then
    return 'null'
  elseif vtype == 'boolean' then
    return v and 'true' or 'false'
  elseif vtype == 'number' then
    if v ~= v then return 'null' end -- NaN
    if v == math.huge or v == -math.huge then return 'null' end
    if v == math.floor(v) and math.abs(v) < 1e15 then
      return string.format('%.0f', v)
    end
    return tostring(v)
  elseif vtype == 'string' then
    return encode_string(v)
  elseif vtype == 'table' then
    if is_array(v) then
      return encode_array(v, indent and (string.rep('  ', level)) or nil, level)
    else
      return encode_object(v, indent and (string.rep('  ', level)) or nil, level)
    end
  else
    return 'null'
  end
end

function json.encode(value, pretty)
  return encode_value(value, pretty and '' or nil, 0)
end

----------------------------------------------------------------
-- Decode
----------------------------------------------------------------

local decode_value -- forward declaration

local function skip_whitespace(s, pos)
  local p = s:find('[^ \t\r\n]', pos)
  return p or #s + 1
end

local function decode_string(s, pos)
  -- pos should be on the opening quote
  if s:byte(pos) ~= 34 then
    return nil, 'expected string at position ' .. pos
  end
  local parts = {}
  local i = pos + 1
  while i <= #s do
    local c = s:byte(i)
    if c == 34 then -- closing quote
      return table.concat(parts), i + 1
    elseif c == 92 then -- backslash
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
      elseif esc == 117 then -- \uXXXX
        local hex = s:sub(i + 1, i + 4)
        local code = tonumber(hex, 16)
        if not code then
          return nil, 'invalid unicode escape at position ' .. i
        end
        if code < 0x80 then
          parts[#parts + 1] = string.char(code)
        elseif code < 0x800 then
          parts[#parts + 1] = string.char(
            0xC0 + math.floor(code / 64),
            0x80 + (code % 64)
          )
        else
          parts[#parts + 1] = string.char(
            0xE0 + math.floor(code / 4096),
            0x80 + math.floor((code % 4096) / 64),
            0x80 + (code % 64)
          )
        end
        i = i + 4
      else
        parts[#parts + 1] = string.char(esc)
      end
      i = i + 1
    else
      -- Find next special character
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
  if not num_str or #num_str == 0 then
    return nil, 'invalid number at position ' .. pos
  end
  local n = tonumber(num_str)
  if not n then
    return nil, 'invalid number at position ' .. pos
  end
  return n, pos + #num_str
end

local function decode_array(s, pos)
  -- pos is on '['
  local arr = {}
  pos = skip_whitespace(s, pos + 1)
  if s:byte(pos) == 93 then -- empty array ']'
    return arr, pos + 1
  end
  while true do
    local val, next_pos = decode_value(s, pos)
    if val == nil and type(next_pos) == 'string' then
      return nil, next_pos
    end
    arr[#arr + 1] = val
    pos = skip_whitespace(s, next_pos)
    local c = s:byte(pos)
    if c == 93 then -- ']'
      return arr, pos + 1
    elseif c == 44 then -- ','
      pos = skip_whitespace(s, pos + 1)
    else
      return nil, 'expected , or ] at position ' .. pos
    end
  end
end

local function decode_object(s, pos)
  -- pos is on '{'
  local obj = {}
  pos = skip_whitespace(s, pos + 1)
  if s:byte(pos) == 125 then -- empty object '}'
    return obj, pos + 1
  end
  while true do
    -- Key
    if s:byte(pos) ~= 34 then
      return nil, 'expected string key at position ' .. pos
    end
    local key, next_pos = decode_string(s, pos)
    if not key then return nil, next_pos end
    pos = skip_whitespace(s, next_pos)
    -- Colon
    if s:byte(pos) ~= 58 then
      return nil, 'expected : at position ' .. pos
    end
    pos = skip_whitespace(s, pos + 1)
    -- Value
    local val
    val, next_pos = decode_value(s, pos)
    if val == nil and type(next_pos) == 'string' then
      return nil, next_pos
    end
    obj[key] = val
    pos = skip_whitespace(s, next_pos)
    local c = s:byte(pos)
    if c == 125 then -- '}'
      return obj, pos + 1
    elseif c == 44 then -- ','
      pos = skip_whitespace(s, pos + 1)
    else
      return nil, 'expected , or } at position ' .. pos
    end
  end
end

-- Sentinel for JSON null
json.null = setmetatable({}, { __tostring = function() return 'null' end })

decode_value = function(s, pos)
  pos = skip_whitespace(s, pos)
  local c = s:byte(pos)
  if c == 34 then -- string
    return decode_string(s, pos)
  elseif c == 123 then -- object '{'
    return decode_object(s, pos)
  elseif c == 91 then -- array '['
    return decode_array(s, pos)
  elseif c == 116 then -- true
    if s:sub(pos, pos + 3) == 'true' then
      return true, pos + 4
    end
    return nil, 'invalid value at position ' .. pos
  elseif c == 102 then -- false
    if s:sub(pos, pos + 4) == 'false' then
      return false, pos + 5
    end
    return nil, 'invalid value at position ' .. pos
  elseif c == 110 then -- null
    if s:sub(pos, pos + 3) == 'null' then
      return json.null, pos + 4
    end
    return nil, 'invalid value at position ' .. pos
  elseif c == 45 or (c >= 48 and c <= 57) then -- number
    return decode_number(s, pos)
  else
    return nil, 'unexpected character at position ' .. pos .. ': ' .. string.char(c or 0)
  end
end

function json.decode(s)
  if type(s) ~= 'string' then
    return nil, 'expected string, got ' .. type(s)
  end
  local value, pos = decode_value(s, 1)
  if value == nil and type(pos) == 'string' then
    return nil, pos
  end
  return value
end

return json
