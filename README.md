# rex-tab-picker

A tab switcher for [Rex](https://www.superlogical.com/rex): one key, a fuzzy list of your open tabs, and you're there. Like tmux's `choose-tree`, so you can keep the sidebar closed and still know where to go.

## Overview

Press the key and a floating [fzf](https://github.com/junegunn/fzf) picker lists your tabs, with the current one selected. Each line shows the tab's name, or its directory when it has none, and the program running in it. Pick one and Rex switches to that tab.

```
rex
  1  ~/.config/rex  claude
  2  aerospace  claude
  3  ~  ssh
agent-inbox
  1  ~/projects/mrkizildag/agent-inbox  nvim
floral-ridge  @arch
  1  ~  bash
```

- **Scope:** the current session's tabs, or every session's tabs in sidebar order.
- **Headers:** a line with each session's name above its tabs. Picking a header jumps to that session's active tab. Without headers the list is flat.
- **Remote:** with every session listed, the sessions of other Rex servers the app is connected to come after your own, marked `@server`. A server reachable under two names is listed once.

## How it works

- `setup` defines two actions. `tab_picker` opens the picker in a floating terminal over the tab you pressed the key in. `tab_picker_go` takes a `target` (`"<session_id> [<window_id>]"`) and asks the app to show it.
- The float runs fzf and hands the choice back with `rex do tab_picker_go`. The app accepts that from the CLI only when Remote Control is on. The action can't wait for the pick itself, because Rex stops taking input while a key-bound action runs.
- Remote servers are the ones the app passes to an action it runs, so they're listed when you open the picker with a key or from the command palette, not from `rex do tab_picker`.

## Install

Clone into Rex's configuration directory:

```sh
git clone https://github.com/mrkizildag/rex-tab-picker ~/.config/rex/rex-tab-picker
```

Add to `~/.config/rex/init.lua`:

```lua
require("rex-tab-picker").setup{}
rex.bind("ctrl+b>w", "tab_picker")
rex.bind("ctrl+b>shift+w", "tab_picker", { scope = "all" })
```

Turn on Remote Control in Rex → Settings → Rex Server, then reload:

```sh
rex config reload
```

Rex loads modules from beside the `init.lua` it opens, so if `init.lua` is a symlink, clone next to the link. fzf 0.60 or newer (for `--accept-nth`) has to be on the `PATH` your login shell sets.

`ctrl+b>w` is a key sequence, like a tmux prefix. If you use one, bind the prefix pressed twice to send it to the terminal:

```lua
rex.bind("ctrl+b>ctrl+b", "pane.send_key", { key = "ctrl+b" })
```

Any key works, and the picker is also in the command palette as "Switch Tab…".

## Options

```lua
require("rex-tab-picker").setup{
  scope   = "session",                -- "session" for this session's tabs, "all" for every session's
  headers = true,                     -- a line with each session's name above its tabs
  remote  = true,                     -- with scope "all", also list other connected Rex servers' sessions
  bounds  = { 0.2, 0.15, 0.6, 0.6 },  -- x, y, width, height of the float, as fractions of the window
}
```

`scope`, `headers` and `remote` can also be set per binding, so one key can list this session and another everything:

```lua
rex.bind("ctrl+b>shift+w", "tab_picker", { scope = "all", headers = false })
```

## Upgrade

```sh
git -C ~/.config/rex/rex-tab-picker pull
rex config reload
```

## Credits

The float-and-hand-back pattern comes from [rex-sessionizer](https://github.com/haxybaxy/rex-sessionizer).
