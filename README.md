# session-manager.wezterm

A WezTerm plugin for workspace session management. Save and restore your workspace layouts (tabs, panes, working directories) across restarts.

Designed to work with WezTerm's [mux server](https://wezterm.org/docs/mux.html) for seamless session persistence.

## Features

- **Save/Restore** workspace state (tabs, panes, cwd, split layout) as JSON
- **Auto-save** at configurable intervals (default: 15 minutes)
- **Workspace selector** via InputSelector (fuzzy search) showing active and saved workspaces
- **Auto-show selector** on GUI attach (when connecting to mux server)
- **Nvim detection** - automatically restarts nvim in panes where it was running
- **Fully configurable** keybindings, save directory, and behavior

## Requirements

- WezTerm >= 20230320-124340-559cb7b0 (plugin API support)

## Installation

Add to your `wezterm.lua`:

```lua
local wezterm = require 'wezterm'
local session_manager = wezterm.plugin.require 'https://github.com/Yuto729/session-manager.wezterm'
local config = wezterm.config_builder()

session_manager.apply_to_config(config)

return config
```

## Configuration

Pass an options table to `apply_to_config` to customize behavior:

```lua
session_manager.apply_to_config(config, {
  -- Directory to store session JSON files
  save_dir = wezterm.home_dir .. '/.local/share/wezterm/sessions',

  -- Auto-save interval in seconds (0 to disable)
  auto_save_interval = 15 * 60,

  -- Show workspace selector when GUI attaches to mux server
  show_selector_on_attach = true,

  -- Keybindings (set to false to disable all default bindings)
  keys = {
    save     = { key = 's', mods = 'LEADER|CTRL' },
    restore  = { key = 'r', mods = 'LEADER|CTRL' },
    selector = { key = 'w', mods = 'LEADER|CTRL' },
  },
})
```

### Disable default keybindings

If you want to set up your own keybindings:

```lua
session_manager.apply_to_config(config, {
  keys = false,
})

-- Custom keybindings using the public API
table.insert(config.keys, {
  key = 'S', mods = 'CTRL|SHIFT',
  action = wezterm.action_callback(function(win, pane)
    session_manager.save_state(win)
  end),
})
```

## Default Keybindings

| Key | Action |
|-----|--------|
| `Leader` + `Ctrl+s` | Save current workspace |
| `Leader` + `Ctrl+r` | Restore current workspace |
| `Leader` + `Ctrl+w` | Open workspace selector |

## Public API

These functions are available on the plugin object for custom integrations:

| Function | Description |
|----------|-------------|
| `save_state(window)` | Save the current workspace state to a JSON file |
| `restore_state(window)` | Restore workspace state from a JSON file |
| `show_workspace_selector(window, pane)` | Show the workspace selector UI |
| `apply_to_config(config, opts)` | Apply plugin config (keybindings, events) |

## How It Works

### Save

Collects the current workspace's tab and pane layout, including:
- Working directory of each pane
- Split direction and position
- Foreground process name (for nvim detection)

Saves as JSON to `~/.local/share/wezterm/sessions/wezterm_state_{workspace_name}.json`.

### Restore

Reads the saved JSON and recreates the tab/pane layout:
- Spawns tabs with the saved working directories
- Splits panes in the recorded directions
- Restarts nvim in panes where it was previously running

Restore requires the target workspace to have a single tab with a single pane (fresh workspace).

### Workspace Selector

Shows an InputSelector with:
- **Active workspaces** from the mux server (labeled `(active)`)
- **Saved workspaces** from JSON files (labeled `(saved)`)
- **Create new workspace** option

Selecting a saved workspace will switch to it and automatically restore the layout.

## Recommended Setup with Mux Server

For the best experience, run WezTerm with a mux server:

1. Start the mux server (e.g., via systemd):
   ```ini
   # ~/.config/systemd/user/wezterm-mux-server.service
   [Unit]
   Description=WezTerm Mux Server
   After=graphical-session.target

   [Service]
   ExecStart=/usr/bin/wezterm-mux-server
   Restart=on-failure
   RestartSec=5

   [Install]
   WantedBy=default.target
   ```

2. Configure unix domain in `wezterm.lua`:
   ```lua
   config.unix_domains = {
     { name = 'unix' },
   }
   ```

3. Connect via `wezterm connect unix` (e.g., set as your desktop entry)

This way:
- **Normal use**: The mux server keeps sessions alive when you close the GUI
- **PC restart**: The plugin's JSON backup restores your workspaces

## License

MIT
