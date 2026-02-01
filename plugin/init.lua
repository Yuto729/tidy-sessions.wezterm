local wezterm = require 'wezterm'
local act = wezterm.action

local M = {}

-- Internal state
local session_dir = nil
local auto_save_interval = 15 * 60
local last_save_time = os.time()
local restoring = false
local process_restore_commands = {}
local toast_message = nil
local toast_expire = 0

--- Default options
local defaults = {
  save_dir = wezterm.home_dir .. '/.local/share/wezterm/sessions',
  auto_save_interval = 15 * 60, -- seconds (0 to disable)
  keys = {
    save     = { key = 's', mods = 'LEADER|CTRL' },
    restore  = { key = 'r', mods = 'LEADER|CTRL' },
    selector = { key = 'w', mods = 'LEADER|CTRL' },
  },
  process_restore_commands = {
    nvim = { cmd = '{tty} .', match = '/bin/nvim' },
  },
}

--- Merge user options with defaults (shallow)
local function merge_opts(user_opts)
  user_opts = user_opts or {}
  local opts = {}
  for k, v in pairs(defaults) do
    if user_opts[k] ~= nil then
      opts[k] = user_opts[k]
    else
      opts[k] = v
    end
  end
  -- Deep merge keys
  if user_opts.keys == false then
    opts.keys = false
  elseif type(user_opts.keys) == 'table' then
    opts.keys = {}
    for k, v in pairs(defaults.keys) do
      if user_opts.keys[k] ~= nil then
        opts.keys[k] = user_opts.keys[k]
      else
        opts.keys[k] = v
      end
    end
  end
  return opts
end

--- Show a temporary message in the right status bar
local function show_toast(window, message, duration_secs)
  toast_message = message
  toast_expire = os.time() + (duration_secs or 3)
  window:set_right_status(wezterm.format {
    { Foreground = { Color = '#a6da95' } },
    { Text = ' ' .. message .. ' ' },
  })
end

--- Extract filesystem path from a cwd URI
local function extract_path(cwd_uri)
  local path = tostring(cwd_uri):gsub('^file://[^/]*', '')
  if path == '' then return wezterm.home_dir end
  return path
end

--- Ensure the sessions directory exists
local function ensure_session_dir()
  os.execute('mkdir -p ' .. session_dir)
end

--- Collect workspace state (tabs, panes, cwd, foreground process)
local function collect_workspace_data(window)
  local workspace_name = window:active_workspace()
  local workspace_data = {
    name = workspace_name,
    tabs = {},
  }

  for _, tab in ipairs(window:mux_window():tabs()) do
    local tab_data = {
      tab_id = tostring(tab:tab_id()),
      panes = {},
    }

    for _, pane_info in ipairs(tab:panes_with_info()) do
      table.insert(tab_data.panes, {
        index = pane_info.index,
        is_active = pane_info.is_active,
        is_zoomed = pane_info.is_zoomed,
        left = pane_info.left,
        top = pane_info.top,
        width = pane_info.width,
        height = pane_info.height,
        cwd = tostring(pane_info.pane:get_current_working_dir()),
        tty = tostring(pane_info.pane:get_foreground_process_name()),
      })
    end

    table.insert(workspace_data.tabs, tab_data)
  end

  return workspace_data
end

--- Get the JSON file path for a workspace
local function session_file_path(workspace_name)
  return session_dir .. '/wezterm_state_' .. workspace_name .. '.json'
end

--- List saved workspace names from JSON files
local function list_saved_workspaces()
  local workspaces = {}
  local handle = io.popen('ls ' .. session_dir .. '/wezterm_state_*.json 2>/dev/null')
  if handle then
    for line in handle:lines() do
      local name = line:match('wezterm_state_(.+)%.json$')
      if name then
        table.insert(workspaces, name)
      end
    end
    handle:close()
  end
  return workspaces
end

--- Save the current workspace state to a JSON file
function M.save_state(window)
  ensure_session_dir()
  local data = collect_workspace_data(window)
  local file_path = session_file_path(data.name)

  local file = io.open(file_path, 'w')
  if file then
    file:write(wezterm.json_encode(data))
    file:close()
    show_toast(window, 'Saved: ' .. data.name)
  else
    show_toast(window, 'Failed to save: ' .. data.name)
  end
end

--- Restore the current workspace state from a JSON file
function M.restore_state(window)
  restoring = true
  local workspace_name = window:active_workspace()
  local file_path = session_file_path(workspace_name)

  local file = io.open(file_path, 'r')
  if not file then
    show_toast(window, 'No saved state for: ' .. workspace_name)
    return
  end

  local content = file:read('*a')
  file:close()

  local workspace_data = wezterm.json_parse(content)
  if not workspace_data or not workspace_data.tabs then
    show_toast(window, 'Invalid state file for: ' .. workspace_name)
    return
  end

  -- Only restore when window has a single tab with a single pane
  local tabs = window:mux_window():tabs()
  if #tabs ~= 1 or #tabs[1]:panes() ~= 1 then
    show_toast(window, 'Restore requires a single tab with a single pane')
    return
  end

  local initial_pane = window:active_pane()

  -- Recreate tabs and panes
  for i, tab_data in ipairs(workspace_data.tabs) do
    local first_cwd = extract_path(tab_data.panes[1].cwd)

    local new_tab
    if i == 1 then
      -- Reuse the existing pane for the first tab
      initial_pane:send_text('cd ' .. first_cwd .. '\n')
      initial_pane:send_text('clear\n')
      new_tab = tabs[1]
    else
      new_tab = window:mux_window():spawn_tab({ cwd = first_cwd })
    end

    if not new_tab then break end

    -- Recreate panes within the tab
    for j, pane_data in ipairs(tab_data.panes) do
      local current_pane
      if j > 1 then
        local direction = 'Right'
        if pane_data.left == tab_data.panes[j - 1].left then
          direction = 'Bottom'
        end

        local cwd = extract_path(pane_data.cwd)
        current_pane = new_tab:active_pane():split({
          direction = direction,
          cwd = cwd,
        })
      else
        current_pane = new_tab:active_pane()
      end

      -- Restart processes based on restore rules
      if current_pane and pane_data.tty then
        for _, rule in pairs(process_restore_commands) do
          if pane_data.tty:find(rule.match, 1, true) then
            local cwd = extract_path(pane_data.cwd)
            local cmd = rule.cmd:gsub('{tty}', pane_data.tty):gsub('{cwd}', cwd)
            current_pane:send_text(cmd .. '\n')
            break
          end
        end
      end
    end
  end

  show_toast(window, 'Restored: ' .. workspace_name)
  -- Re-enable auto-save after a delay to let tabs fully initialize
  wezterm.time.call_after(10, function()
    restoring = false
  end)
end

--- Show an InputSelector with active mux workspaces, saved workspaces, and a create option
function M.show_workspace_selector(window, pane)
  -- Active workspaces from the mux server
  local mux_workspaces = wezterm.mux.get_workspace_names()

  -- Saved workspaces from JSON files
  local saved_workspaces = list_saved_workspaces()

  -- Merge with deduplication
  local seen = {}
  local choices = {}

  for _, name in ipairs(mux_workspaces) do
    if not seen[name] then
      seen[name] = true
      table.insert(choices, {
        id = 'mux:' .. name,
        label = name .. ' (active)',
      })
    end
  end

  for _, name in ipairs(saved_workspaces) do
    if not seen[name] then
      seen[name] = true
      table.insert(choices, {
        id = 'saved:' .. name,
        label = name .. ' (saved)',
      })
    end
  end

  table.insert(choices, {
    id = 'new',
    label = '+ Create new workspace',
  })

  window:perform_action(
    act.InputSelector {
      title = 'Select Workspace',
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(win, _, id, label)
        if not id then return end

        if id == 'new' then
          win:perform_action(act.PromptInputLine {
            description = 'New workspace name:',
            action = wezterm.action_callback(function(w, p, line)
              if line and line ~= '' then
                w:perform_action(act.SwitchToWorkspace { name = line }, p)
              end
            end),
          }, pane)
        elseif id:match('^mux:') then
          local name = id:gsub('^mux:', '')
          win:perform_action(act.SwitchToWorkspace { name = name }, pane)
        elseif id:match('^saved:') then
          local name = id:gsub('^saved:', '')
          win:perform_action(act.SwitchToWorkspace { name = name }, pane)
          -- Restore after workspace switch
          wezterm.time.call_after(1, function()
            M.restore_state(win)
          end)
        end
      end),
    },
    pane
  )
end

--- Auto-save (called from update-status event, throttled by interval)
local function auto_save(window)
  if auto_save_interval <= 0 then return end
  if restoring then return end

  local now = os.time()
  if now - last_save_time >= auto_save_interval then
    last_save_time = now
    ensure_session_dir()
    local data = collect_workspace_data(window)
    local file_path = session_file_path(data.name)
    local file = io.open(file_path, 'w')
    if file then
      file:write(wezterm.json_encode(data))
      file:close()
      wezterm.log_info('session-manager: auto-saved workspace: ' .. data.name)
    end
  end
end

--- Apply plugin configuration. Call this from your wezterm.lua.
---
--- @param config table  The config builder from wezterm.config_builder()
--- @param opts table|nil  Optional configuration overrides
function M.apply_to_config(config, opts)
  opts = merge_opts(opts)

  -- Store resolved config
  session_dir = opts.save_dir
  auto_save_interval = opts.auto_save_interval
  process_restore_commands = opts.process_restore_commands or {}

  -- Register keybindings
  if opts.keys then
    config.keys = config.keys or {}

    if opts.keys.save then
      table.insert(config.keys, {
        key = opts.keys.save.key,
        mods = opts.keys.save.mods,
        action = wezterm.action_callback(function(win, pane)
          M.save_state(win)
        end),
      })
    end

    if opts.keys.restore then
      table.insert(config.keys, {
        key = opts.keys.restore.key,
        mods = opts.keys.restore.mods,
        action = wezterm.action_callback(function(win, pane)
          M.restore_state(win)
        end),
      })
    end

    if opts.keys.selector then
      table.insert(config.keys, {
        key = opts.keys.selector.key,
        mods = opts.keys.selector.mods,
        action = wezterm.action_callback(function(win, pane)
          M.show_workspace_selector(win, pane)
        end),
      })
    end
  end

  -- Register update-status handler for auto-save and toast expiry
  wezterm.on('update-status', function(window, pane)
    -- Clear expired toast message
    if toast_message and os.time() >= toast_expire then
      toast_message = nil
      window:set_right_status('')
    end

    -- Auto-save
    if opts.auto_save_interval > 0 then
      auto_save(window)
    end
  end)

end

return M
