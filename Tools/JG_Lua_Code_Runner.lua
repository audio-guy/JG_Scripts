-- @description Lua Code Runner
-- @author JG
-- @version 1.0.0
-- @about
--   Interactive Lua code runner for REAPER.
--   Write or paste Lua code and execute it directly without saving or importing scripts.
--   Output and errors are displayed in a live console area.
--   Supports Ctrl+Enter to run, Tab indentation, and sandbox print() capture.

local ctx = reaper.ImGui_CreateContext('Lua Code Runner')
local code = ""
local output = ""
local font_mono = reaper.ImGui_CreateFont('monospace', 14)
reaper.ImGui_Attach(ctx, font_mono)

local WINDOW_W, WINDOW_H = 700, 550
local focus_editor = true  -- grab focus on first frame

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

local function loop()
  reaper.ImGui_SetNextWindowSize(ctx, WINDOW_W, WINDOW_H, reaper.ImGui_Cond_FirstUseEver())

  local visible, open = reaper.ImGui_Begin(ctx, 'Lua Code Runner', true)

  if visible then
    -- Toolbar
    if reaper.ImGui_Button(ctx, '▶  Run (Ctrl+Enter)', 160, 28) then
      run_code()
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, '🗑  Clear Code', 120, 28) then
      code = ""
      focus_editor = true
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, '✖  Clear Output', 130, 28) then
      output = ""
    end

    reaper.ImGui_Separator(ctx)

    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    local editor_h = avail_h * 0.6

    reaper.ImGui_PushFont(ctx, font_mono, 14)

    reaper.ImGui_Text(ctx, "Code:")

    -- Set keyboard focus on the editor when requested
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
    local out_h = reaper.ImGui_GetContentRegionAvail(ctx)
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
    if reaper.ImGui_DestroyContext then
      reaper.ImGui_DestroyContext(ctx)
    end
  end
end

loop()