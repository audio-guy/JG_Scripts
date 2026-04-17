-- @description Lua Code Runner
-- @author JG
-- @version 1.2.1
-- @about
--   Interactive Lua code runner for REAPER.
--   Write or paste Lua code and execute it directly without saving or importing scripts.
--   Output and errors are displayed in a live console area.
--   Supports Ctrl+Enter to run, Tab indentation, and sandbox print() capture.
--   Built-in Claude prompt: write a natural-language prompt and have Claude generate
--   Lua code directly into the editor.
--   Uses the Claude Code CLI (`claude -p`), so it runs through your Pro/Max subscription —
--   no API key required and no per-token cost. Requires `claude` to be installed and
--   logged in (claude.ai/code).

local ctx = reaper.ImGui_CreateContext('Lua Code Runner')
local code = ""
local output = ""
local font_mono = reaper.ImGui_CreateFont('monospace', 14)
reaper.ImGui_Attach(ctx, font_mono)

local WINDOW_W, WINDOW_H = 700, 700
local focus_editor = true

-- ============================================================================
-- Claude Code CLI integration
-- ============================================================================

local EXT_SECTION = "JG_LuaCodeRunner"
local CLAUDE_MODEL = "claude-opus-4-7"
local CLAUDE_SYSTEM_PROMPT = table.concat({
  "You generate Lua code for REAPER's ReaScript API.",
  "Output ONLY raw Lua code that can be executed directly — no explanations, no markdown fences, no commentary.",
  "Use reaper.* API calls. Use print() for any output the user should see (it is captured into a console).",
  "Keep code concise and self-contained.",
}, " ")

-- Optional override for the `claude` binary path (in case it's not in PATH).
-- Leave empty to use whatever a login shell finds.
local claude_cli_path_input = reaper.GetExtState(EXT_SECTION, "claude_cli_path") or ""

local prompt_text = ""
local show_settings = false
local pending_request = nil   -- {sentinel, response_file, prompt_file, started_at}
local generating = false
local last_status = ""

-- ---------- helpers ----------

local function shell_escape(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function temp_path(suffix)
  local base = reaper.GetResourcePath() .. "/Data/JG_LuaCodeRunner_tmp"
  reaper.RecursiveCreateDirectory(base, 0)
  return string.format("%s/%d_%d%s", base, os.time(), math.random(1, 1e9), suffix)
end

-- Strip ```lua ... ``` or ``` ... ``` fences if Claude returned any.
local function strip_code_fences(s)
  local stripped = s:match('^%s*```[%w_]*%s*\n(.-)\n```%s*$')
  if stripped then return stripped end
  stripped = s:match('^%s*```[%w_]*%s*(.-)%s*```%s*$')
  if stripped then return stripped end
  return s
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ---------- async run via login shell + temp files ----------

local function start_claude_request(user_prompt)
  local prompt_file   = temp_path("_prompt.txt")
  local response_file = temp_path("_resp.txt")
  local sentinel      = temp_path(".done")

  local f = io.open(prompt_file, "wb")
  if not f then
    last_status = "❌ Could not create temp file"
    return false
  end
  f:write(user_prompt)
  f:close()

  -- Resolve `claude` binary: explicit override > whatever a login shell finds.
  local claude_bin = claude_cli_path_input
  if claude_bin == nil or claude_bin == "" then claude_bin = "claude" end

  -- Inner shell command:
  --   claude -p --model X --output-format text --append-system-prompt "..." < prompt > resp 2>&1
  --   echo $? > sentinel
  -- Using a login shell (sh -lc) so PATH from ~/.zprofile / ~/.bash_profile is loaded.
  local inner = string.format(
    [[%s -p --model %s --output-format text --append-system-prompt %s < %s > %s 2>&1; echo $? > %s; rm -f %s]],
    claude_bin,
    CLAUDE_MODEL,
    shell_escape(CLAUDE_SYSTEM_PROMPT),
    shell_escape(prompt_file),
    shell_escape(response_file),
    shell_escape(sentinel),
    shell_escape(prompt_file)
  )

  local cmd = string.format([[sh -lc %s &]], shell_escape(inner))
  reaper.ExecProcess(cmd, -1)

  pending_request = {
    sentinel      = sentinel,
    response_file = response_file,
    prompt_file   = prompt_file,
    started_at    = reaper.time_precise(),
  }
  generating = true
  last_status = "⏳ Generating with " .. CLAUDE_MODEL .. " via Claude Code CLI ..."
  return true
end

local function poll_claude_request()
  if not pending_request then return end

  if reaper.time_precise() - pending_request.started_at > 180 then
    pending_request = nil
    generating = false
    last_status = "❌ Request timed out after 180s"
    return
  end

  local sf = io.open(pending_request.sentinel, "rb")
  if not sf then return end  -- not done yet
  local exit_code_str = sf:read("*all")
  sf:close()
  local exit_code = tonumber(trim(exit_code_str or "")) or -1

  local rf = io.open(pending_request.response_file, "rb")
  local response = rf and rf:read("*all") or ""
  if rf then rf:close() end

  os.remove(pending_request.sentinel)
  os.remove(pending_request.response_file)
  os.remove(pending_request.prompt_file)
  pending_request = nil
  generating = false

  if exit_code ~= 0 then
    last_status = string.format("❌ claude exited %d:\n%s", exit_code, trim(response))
    return
  end

  local text = trim(response)
  if text == "" then
    last_status = "❌ Empty response from claude"
    return
  end

  code = strip_code_fences(text)
  focus_editor = true
  last_status = "✅ Code generated — review, then Run (Ctrl+Enter)"
end

local function generate_from_prompt()
  if generating then return end
  if prompt_text == nil or trim(prompt_text) == "" then
    last_status = "❌ Enter a prompt first"
    return
  end
  start_claude_request(prompt_text)
end

-- ============================================================================
-- Sandbox / executor
-- ============================================================================

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
      reaper.ImGui_TextWrapped(ctx,
        "Uses the Claude Code CLI (`claude -p`) — runs through your Pro/Max " ..
        "subscription. Make sure `claude` is installed and logged in.")
      reaper.ImGui_Text(ctx, "Optional: explicit path to the `claude` binary (leave empty for auto):")
      local _, avail_w_s = reaper.ImGui_GetContentRegionAvail(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, avail_w_s - 90)
      local p_changed, p_new = reaper.ImGui_InputText(ctx, '##cli_path', claude_cli_path_input)
      if p_changed then claude_cli_path_input = p_new end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, 'Save', 80, 22) then
        reaper.SetExtState(EXT_SECTION, "claude_cli_path", claude_cli_path_input or "", true)
        last_status = "✅ Path saved"
      end
      reaper.ImGui_Text(ctx, "Model: " .. CLAUDE_MODEL)
      reaper.ImGui_Separator(ctx)
    end

    -- Prompt area
    reaper.ImGui_Text(ctx, "Prompt (ask Claude to generate Lua code):")
    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
    local pr_changed, pr_new = reaper.ImGui_InputTextMultiline(
      ctx, '##prompt', prompt_text,
      avail_w, 70
    )
    if pr_changed then prompt_text = pr_new end

    local is_generating_now = generating
    local gen_label = is_generating_now and '⏳  Generating...' or '✨  Generate Code'
    if is_generating_now then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_Button(ctx, gen_label, 180, 28) then
      generate_from_prompt()
    end
    if is_generating_now then reaper.ImGui_EndDisabled(ctx) end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, '🗑  Clear Prompt', 130, 28) then
      prompt_text = ""
    end

    if last_status ~= "" then
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
