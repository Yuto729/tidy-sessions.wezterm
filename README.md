# tidy-sessions.wezterm

A WezTerm plugin for workspace session management. Save and restore your workspace layouts (tabs, panes, working directories) across restarts.

## Features

- **Save/Restore** workspace state (tabs, panes, cwd, split layout) as JSON
- **Auto-save** registered workspaces at configurable intervals (default: 15 minutes)
- **Workspace selector** with fuzzy search — switch, create, restore, and delete workspaces
- **Registered workspace tracking** — only explicitly saved workspaces are auto-saved; random/temporary workspaces are ignored
- **Configurable process restore** — automatically restart processes (e.g., nvim, claude) on restore
- **Auto-cleanup** — empty unregistered workspaces are closed when switching away
- **Saved workspace limit** — prevent unbounded growth with a configurable maximum

## Requirements

- WezTerm >= 20230320-124340-559cb7b0 (plugin API support)

## Installation

Add to your `wezterm.lua`:

```lua
local wezterm = require 'wezterm'
local session_manager = wezterm.plugin.require 'https://github.com/Yuto729/tidy-sessions.wezterm'
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

  -- Maximum number of saved workspaces
  max_saved_workspaces = 10,

  -- Keybindings (set to false to disable all default bindings)
  keys = {
    save     = { key = 's', mods = 'LEADER|CTRL' },
    restore  = { key = 'r', mods = 'LEADER|CTRL' },
    selector = { key = 'w', mods = 'LEADER|CTRL' },
  },

  -- Processes to restart on restore (substring match on process path)
  process_restore_commands = {
    nvim   = { cmd = '{tty} .', match = '/bin/nvim' },
    claude = { cmd = 'claude --resume', match = 'claude/versions/' },
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

## Workspace Selector

The selector (`Leader+Ctrl+w`) shows:

- **Active workspaces** — currently open (labeled `(active)` or `(active, unsaved)`)
- **Saved workspaces** — previously saved but not currently active (labeled `(saved)`)
- **+ Create new workspace** — prompts for a name, creates and saves immediately
- **- Delete saved workspaces** — remove saved session files (repeatable, Escape to finish)

When the saved workspace limit is reached, creating a new workspace will prompt you to delete existing ones first.

## How It Works

### Registered Workspaces

A workspace is "registered" when it has a save file. Only registered workspaces are auto-saved.

- **Workspaces created via the selector** are saved immediately (registered)
- **Random workspaces** (from New Window or initial startup) are not registered unless manually saved with `Leader+Ctrl+s`
- **Auto-save** only updates existing save files, never creates new ones

### Save

Collects the current workspace's tab and pane layout, including:
- Working directory of each pane
- Split direction and position
- Foreground process name (for process restore)

Saves as JSON to `~/.local/share/wezterm/sessions/wezterm_state_{workspace_name}.json`.

### Restore

Reads the saved JSON and recreates the tab/pane layout:
- Spawns tabs with the saved working directories
- Splits panes in the recorded directions
- Restarts configured processes (e.g., nvim, claude)

Restore requires the target workspace to have a single tab with a single pane (fresh workspace).

### Process Restore

Configure `process_restore_commands` to automatically restart processes on restore. Each rule has:
- `match` — substring to find in the process path (e.g., `/bin/nvim`, `claude/versions/`)
- `cmd` — command to execute (supports `{tty}` and `{cwd}` placeholders)

### Auto-cleanup

When switching workspaces via the selector, the previous workspace is automatically closed if it is:
1. **Unregistered** (no save file)
2. **Empty** (single tab, single pane, shell only)

## Public API

| Function | Description |
|----------|-------------|
| `save_state(window)` | Save the current workspace state to a JSON file |
| `restore_state(window)` | Restore workspace state from a JSON file |
| `show_workspace_selector(window, pane)` | Show the workspace selector UI |
| `apply_to_config(config, opts)` | Apply plugin config (keybindings, auto-save) |

## License

MIT
