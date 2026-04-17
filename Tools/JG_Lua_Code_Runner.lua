-- @description Lua Code Runner
-- @author JG
-- @version 1.1.0
-- @about
--   Interactive Lua code runner for REAPER.
--   Write or paste Lua code and execute it directly without saving or importing scripts.
--   Output and errors are displayed in a live console area.
--   Supports Ctrl+Enter to run, Tab indentation, and sandbox print() capture.
--   Built-in Claude AI prompt: write a natural-language prompt and have Claude generate
--   Lua code directly into the editor (requires Anthropic API key).

local ctx = reaper.ImGui_CreateContext('Lua Code Runner')
local code = ""
local output = ""
local font_mono = reaper.ImGui_CreateFont('monospace', 14)
reaper.ImGui_Attach(ctx, font_mono)

local WINDOW_W, WINDOW_H = 700, 700
local focus_editor = true  -- grab focus on first frame

-- ============================================================================
-- Claude AI integration
-- ============================================================================

local EXT_SECTION = "JG_LuaCodeRunner"
local CLAUDE_MODEL = "claude-opus-4-7"
local CLAUDE_SYSTEM_PROMPT = table.concat({
  "You generate Lua code for REAPER's ReaScript API.",
  "Output ONLY raw Lua code that can be executed directly — no explanations, no markdown fences, no commentary.",
  "Use reaper.* API calls. Use print() for any output the user should see (it is captured into a console).",
  "Keep code concise and self-contained.",
}, " ")

local prompt_text = ""
local show_settings = false
local api_key_input = reaper.GetExtState(EXT_SECTION, "api_key") or ""
local pending_request = nil   -- {sentinel, response_file, started_at}
local generating = false
local last_status = ""

-- ---------- minimal JSON helpers ----------

local function json_escape_string(s)
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"', '\\"')
  s = s:gsub('\b', '\\b')
  s = s:gsub('\f', '\\f')
  s = s:gsub('\n', '\\n')
  s = s:gsub('\r', '\\r')
  s = s:gsub('\t', '\\t')
  s = s:gsub('[%z\1-\31]', function(c) return string.format('\\u%04x', c:byte()) end)
  return s
end

-- Read a JSON string starting just after the opening quote at start_pos.
-- Returns (decoded_string, position_after_closing_quote).
local function json_read_string(s, start_pos)
  local result = {}
  local i = start_pos
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(result), i + 1
    elseif c == '\\' then
      local n = s:sub(i + 1, i + 1)
      if n == 'n' then table.insert(result, '\n'); i = i + 2
      elseif n == 't' then table.insert(result, '\t'); i = i + 2
      elseif n == 'r' then table.insert(result, '\r'); i = i + 2
      elseif n == 'b' then table.insert(result, '\b'); i = i + 2
      elseif n == 'f' then table.insert(result, '\f'); i = i + 2
      elseif n == '"' then table.insert(result, '"'); i = i + 2
      elseif n == '\\' then table.insert(result, '\\'); i = i + 2
      elseif n == '/' then table.insert(result, '/'); i = i + 2
      elseif n == 'u' then
        local hex = s:sub(i + 2, i + 5)
        local cp = tonumber(hex, 16) or 0
        if cp < 0x80 then
          table.insert(result, string.char(cp))
        elseif cp < 0x800 then
          table.insert(result, string.char(0xC0 + math.floor(cp / 64), 0x80 + (cp % 64)))
        else
          table.insert(result, string.char(
            0xE0 + math.floor(cp / 4096),
            0x80 + (math.floor(cp / 64) % 64),
            0x80 + (cp % 64)))
        end
        i = i + 6
      else
        table.insert(result, n); i = i + 2
      end
    else
      table.insert(result, c); i = i + 1
    end
  end
  return table.concat(result), i
end

-- Extract the first content[].text from a Claude API response.
local function extract_text_from_response(json_str)
  local _, content_end = json_str:find('"content"%s*:%s*%[')
  if not content_end then return nil end
  local _, text_end = json_str:find('"text"%s*:%s*"', content_end)
  if not text_end then return nil end
  local txt = json_read_string(json_str, text_end + 1)
  return txt
end

-- Extract an error message from a Claude API error response.
local function extract_error_from_response(json_str)
  local _, msg_end = json_str:find('"message"%s*:%s*"')
  if not msg_end then return nil end
  return (json_read_string(json_str, msg_end + 1))
end

-- Strip ```lua ... ``` or ``` ... ``` fences if Claude returned any.
local function strip_code_fences(s)
  -- ```lua\n...\n```
  local stripped = s:match('^%s*```[%w_]*%s*\n(.-)\n```%s*$')
  if stripped then return stripped end
  -- single-line variant
  stripped = s:match('^%s*```[%w_]*%s*(.-)%s*```%s*$')
  if stripped then return stripped end
  return s
end

-- ---------- async HTTP via curl + temp files ----------

local function temp_path(suffix)
  local base = reaper.GetResourcePath() .. "/Data/JG_LuaCodeRunner_tmp"
  reaper.RecursiveCreateDirectory(base, 0)
  return string.format("%s/%d_%d%s", base, os.time(), math.random(1, 1e9), suffix)
end

local function shell_escape(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function start_claude_request(user_prompt, api_key)
  local body = string.format(
    '{"model":"%s","max_tokens":4096,"system":"%s","messages":[{"role":"user","content":"%s"}]}',
    CLAUDE_MODEL,
    json_escape_string(CLAUDE_SYSTEM_PROMPT),
    json_escape_string(user_prompt)
  )

  local body_file = temp_path(".json")
  local response_file = temp_path("_resp.json")
  local sentinel = temp_path(".done")

  -- write body
  local f = io.open(body_file, "wb")
  if not f then
    last_status = "❌ Could not create temp file"
    return false
  end
  f:write(body)
  f:close()

  -- Build shell command. Use sh -c so we can chain && and background with &.
  local cmd = string.format(
    [[sh -c %s &]],
    shell_escape(string.format(
      [[curl -sS -X POST https://api.anthropic.com/v1/messages ]] ..
      [[-H "x-api-key: %s" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" ]] ..
      [[--data-binary @%s -o %s; touch %s; rm -f %s]],
      api_key, body_file, response_file, sentinel, body_file
    ))
  )

  -- timeout < 0 → run in background, do not wait
  reaper.ExecProcess(cmd, -1)

  pending_request = {
    sentinel = sentinel,
    response_file = response_file,
    body_file = body_file,
    started_at = reaper.time_precise(),
  }
  generating = true
  last_status = "⏳ Generating with " .. CLAUDE_MODEL .. " ..."
  return true
end

local function poll_claude_request()
  if not pending_request then return end

  -- timeout safety net (90s)
  if reaper.time_precise() - pending_request.started_at > 90 then
    pending_request = nil
    generating = false
    last_status = "❌ Request timed out after 90s"
    return
  end

  local f = io.open(pending_request.sentinel, "rb")
  if not f then return end  -- not done yet
  f:close()

  local rf = io.open(pending_request.response_file, "rb")
  local response = rf and rf:read("*all") or ""
  if rf then rf:close() end

  os.remove(pending_request.sentinel)
  os.remove(pending_request.response_file)
  os.remove(pending_request.body_file)
  pending_request = nil
  generating = false

  if response == "" then
    last_status = "❌ Empty response (network error or curl failed)"
    return
  end

  -- error response?
  if response:find('"type"%s*:%s*"error"') then
    local msg = extract_error_from_response(response) or "Unknown error"
    last_status = "❌ API error: " .. msg
    return
  end

  local text = extract_text_from_response(response)
  if not text or text == "" then
    last_status = "❌ Could not parse response"
    return
  end

  code = strip_code_fences(text)
  focus_editor = true
  last_status = "✅ Code generated — review, then Run (Ctrl+Enter)"
end

local function generate_from_prompt()
  if generating then return end
  if prompt_text == nil or prompt_text:gsub("%s", "") == "" then
    last_status = "❌ Enter a prompt first"
    return
  end
  local key = reaper.GetExtState(EXT_SECTION, "api_key")
  if key == nil or key == "" then
    last_status = "❌ No API key set — open Settings"
    show_settings = true
    return
  end
  start_claude_request(prompt_text, key)
end

-- ============================================================================
-- Sandbox / executor
-- ============================================================================

-- Redirect print() to output buffer
local function make_sandbox_env()
  local env = setmetatable({}, {__index = _G})
  env.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do
      parts[i] = tostring(select(i, ...))
    end
    output = output .. table.concat(parts, "\t") .. "\n"
  end
  return env
end

local function run_code()
  output = ""
  local fn, err = load(code, "runner", "t", make_sandbox_env())
  if not fn then
    output = "❌ Syntax error:\n" .. tostring(err)
    return
  end
  local ok, run_err = pcall(fn)
  if not ok then
    output = "❌ Runtime error:\n" .. tostring(run_err)
  elseif output == "" then
    output = "✅ Executed successfully (no output)"
  end
end

-- ============================================================================
-- UI loop
-- ============================================================================

local function loop()
  poll_claude_request()

  reaper.ImGui_SetNextWindowSize(ctx, WINDOW_W, WINDOW_H, reaper.ImGui_Cond_FirstUseEver())

  local visible, open = reaper.ImGui_Begin(ctx, 'Lua Code Runner', true)

  if visible then
    -- Toolbar
    if reaper.ImGui_Button(ctx, '▶  Run (Ctrl+Enter)', 160, 28) then
      run_code()
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, '🗑  Clear Code', 110, 28) then
      code = ""
      focus_editor = true
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, '✖  Clear Output', 120, 28) then
      output = ""
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, '⚙  Settings', 100, 28) then
      show_settings = not show_settings
    end

    reaper.ImGui_Separator(ctx)

    -- Settings panel (collapsible)
    if show_settings then
      reaper.ImGui_Text(ctx, "Anthropic API key (stored in REAPER ExtState):")
      local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, avail_w - 180)
      local k_changed, k_new = reaper.ImGui_InputText(
        ctx, '##apikey', api_key_input,
        reaper.ImGui_InputTextFlags_Password()
      )
      if k_changed then api_key_input = k_new end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, 'Save key', 80, 22) then
        reaper.SetExtState(EXT_SECTION, "api_key", api_key_input or "", true)
        last_status = "✅ API key saved"
      end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, 'Clear', 60, 22) then
        api_key_input = ""
        reaper.DeleteExtState(EXT_SECTION, "api_key", true)
        last_status = "✅ API key cleared"
      end
      reaper.ImGui_Text(ctx, "Model: " .. CLAUDE_MODEL)
      reaper.ImGui_Separator(ctx)
    end

    -- Prompt area
    reaper.ImGui_Text(ctx, "Prompt (ask Claude to generate Lua code):")
    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
    local p_changed, p_new = reaper.ImGui_InputTextMultiline(
      ctx, '##prompt', prompt_text,
      avail_w, 70
    )
    if p_changed then prompt_text = p_new end

    local gen_label = generating and '⏳  Generating...' or '✨  Generate Code'
    if generating then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_Button(ctx, gen_label, 180, 28) then
      generate_from_prompt()
    end
    if generating then reaper.ImGui_EndDisabled(ctx) end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, '🗑  Clear Prompt', 130, 28) then
      prompt_text = ""
    end

    if last_status ~= "" then
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_TextWrapped(ctx, last_status)
    end

    reaper.ImGui_Separator(ctx)

    -- Editor + output
    local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    local editor_h = avail_h * 0.55

    reaper.ImGui_PushFont(ctx, font_mono, 14)

    reaper.ImGui_Text(ctx, "Code:")

    if focus_editor then
      reaper.ImGui_SetKeyboardFocusHere(ctx)
      focus_editor = false
    end

    local changed, new_code = reaper.ImGui_InputTextMultiline(
      ctx, '##code', code,
      avail_w, editor_h - 20,
      reaper.ImGui_InputTextFlags_AllowTabInput()
    )
    if changed then code = new_code end

    -- Ctrl+Enter shortcut
    if reaper.ImGui_IsItemFocused(ctx) then
      local ctrl = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftCtrl())
                or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_RightCtrl())
      local enter = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter())
      if ctrl and enter then
        run_code()
      end
    end

    reaper.ImGui_Separator(ctx)

    reaper.ImGui_Text(ctx, "Output:")
    local _, out_h = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_InputTextMultiline(
      ctx, '##output', output,
      avail_w, out_h,
      reaper.ImGui_InputTextFlags_ReadOnly()
    )

    reaper.ImGui_PopFont(ctx)
  end

  reaper.ImGui_End(ctx)

  if open then
    reaper.defer(loop)
  else
    ctx = nil
  end
end

loop()
