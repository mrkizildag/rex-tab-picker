-- rex-tab-picker: a floating fzf list of open tabs to jump to, without the sidebar.
--
--   require("rex-tab-picker").setup{ scope = "session", headers = true, remote = true }
--
-- scope "session" lists the current session's tabs, "all" every session's.
-- headers puts each session's name above its tabs; picking a name jumps to
-- that session's active tab. remote adds the sessions of the other Rex
-- servers the app is connected to when scope is "all". Each can be
-- overridden per binding:
--
--   rex.bind("ctrl+b>w", "tab_picker", { scope = "all", headers = false })
--
-- The float hands the pick back with `rex do tab_picker_go`: a key-bound
-- action can't wait for fzf, because the app takes no input while it runs.

local M = {}

M.options = {
  scope = "session",
  headers = true,
  remote = true,
  -- x, y, width, height as fractions of the window
  bounds = { 0.2, 0.15, 0.6, 0.6 },
}

local SCOPES = { session = true, all = true }
local TERMINAL = "com.superlogical.terminal"
local BOLD, DIM, RESET = "\27[1;34m", "\27[2m", "\27[0m"

-- Reads the pick and hands it back. Exits 0 even on Esc: Rex keeps a pane
-- open after a quick failure, which would leave the float on screen.
local PICK = [[
sel=$(fzf --ansi --layout=reverse --no-sort --delimiter='\t' --with-nth=2.. \
  --accept-nth=1 --prompt='tab> ' --bind "load:pos($2)" < "$1")
rm -f "$1"
if [ -n "$sel" ] && ! rex do tab_picker_go target="$sel" >/dev/null; then
  read -r -p 'Could not switch tabs. Press Enter to close.' _
fi
exit 0
]]

local LOCAL = { name = nil, call = rex.call }

local function call(server, method, args)
  local result, err = server.call(method, args)
  if result == nil then
    error("tab picker: " .. (server.name or "local") .. ": " .. method .. ": " .. tostring(err), 0)
  end
  return result
end

-- Calls about a session only work while attached to it; the action starts
-- attached to its own session, so callers attach back when done.
local function attach(server, session_id)
  return call(server, "session.attach", { session_id = session_id }).view
end

-- rex.block.call only reaches the action's own session, so name it explicitly.
local function terminal(server, session_id, block_id, method)
  return server.call(TERMINAL .. "." .. method, { session_id = session_id, block_id = block_id, args = {} })
end

-- Rex labels an unnamed tab "Window <hex>"; show its directory instead,
-- shortened against the home directory of the machine it runs on.
local function tab_name(w, pwd, home)
  if w.label ~= nil and w.label ~= "" and not w.label:match("^Window %x+$") then return w.label end
  local path = pwd and pwd.pwd and pwd.pwd:gsub("^file://[^/]*", "")
  if path == nil then return w.label or "tab" end
  path = path:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
  if home ~= nil and path:sub(1, #home) == home then path = "~" .. path:sub(#home + 1) end
  return path
end

-- This server, then each remote one. A remote can be reachable under several
-- names (a hostname and a Tailscale address), so later names of a server
-- already listed are dropped by the session check in entries.
local function servers(include_remote)
  local list = { LOCAL }
  if not include_remote then return list end
  for _, name in ipairs(rex.servers()) do
    local ok, remote = pcall(rex.server, name)
    if ok then
      list[#list + 1] = { name = name, call = remote.call }
    else
      rex.log("warn", "tab picker: skipping server " .. name .. ": " .. tostring(remote))
    end
  end
  return list
end

-- The session's tabs as lines: the target ("session window"), a tab, then
-- what fzf shows. Marks the current tab in result.current.
local function session_lines(ctx, server, s, headers, result)
  local view = attach(server, s.session_id)
  local where = server.name and ("  " .. DIM .. "@" .. server.name .. RESET) or ""
  local indent = ""
  if headers then
    result.lines[#result.lines + 1] = s.session_id .. "\t" .. BOLD .. (s.label or "session") .. RESET .. where
    indent, where = "  ", ""
  end
  for i, w in ipairs(view.windows) do
    local p = terminal(server, s.session_id, w.focused_block_id, "process")
    local prog = p and p.foreground and p.foreground.name or ""
    local name = tab_name(w, terminal(server, s.session_id, w.focused_block_id, "pwd"), p and p.home)
    local detail = (prog ~= "" and prog ~= name) and ("  " .. DIM .. prog .. RESET) or ""
    result.lines[#result.lines + 1] = string.format("%s %s\t%s%d  %s%s%s",
      s.session_id, w.window_id, indent, i, name, detail, where)
    if s.session_id == ctx.session_id and w.window_id == view.active_window_id then
      result.current = #result.lines
    end
  end
end

-- Sessions in sidebar order (session.list's order), this server's first.
local function entries(ctx, scope, headers, remote)
  local result, seen = { lines = {}, current = 1 }, {}
  for _, server in ipairs(servers(scope == "all" and remote)) do
    local ok, err = pcall(function()
      for _, s in ipairs(call(server, "session.list").sessions) do
        local wanted = scope == "all" or s.session_id == ctx.session_id
        if wanted and not seen[s.session_id] then
          seen[s.session_id] = true
          session_lines(ctx, server, s, headers, result)
        end
      end
    end)
    if not ok then
      if server == LOCAL then error(err, 0) end
      rex.log("warn", tostring(err))
    end
  end
  attach(LOCAL, ctx.session_id)
  return result.lines, result.current
end

-- The tab holding the pane the key was pressed in. The server's active
-- window can lag behind the tab the app shows, so the float can't rely on it.
local function window_of(block_id)
  local view, err = rex.session.view{}
  if view == nil then error("tab picker: session.view: " .. tostring(err), 0) end
  for _, w in ipairs(view.windows) do
    for _, layer in ipairs(w.layers or {}) do
      for _, b in ipairs(layer.blocks or {}) do
        if b.block_id == block_id then return w.window_id end
      end
    end
  end
  return nil
end

function M.open(ctx, args)
  local function option(name)
    if args[name] == nil then return M.options[name] end
    return args[name]
  end

  local lines, current = entries(ctx, option("scope"), option("headers"), option("remote"))
  local window_id = window_of(ctx.block_id)
  local path = os.tmpname()
  local file = assert(io.open(path, "w"))
  file:write(table.concat(lines, "\n"), "\n")
  file:close()

  local layer, err = rex.session.new_layer{
    window_id = window_id,
    bounds = M.options.bounds,
    focus = true,
    layout = {
      block = {
        flavor = TERMINAL .. ".shell",
        label = "tabs",
        options = { command = { "bash", "-c", PICK, "tab-picker", path, tostring(current) } },
      },
    },
  }
  if layer == nil then
    os.remove(path)
    error("tab picker: " .. tostring(err), 0)
  end
end

-- The app, not the server, decides which session and tab it shows, so the
-- switch goes to it; it finds remote sessions by ID too. From the CLI the
-- app accepts this only with Remote Control on (Settings → Rex Server).
local function show(ctx, select_args)
  if ctx.origin == "key" or ctx.origin == "palette" then
    rex.client.queue("session.select", select_args)
    return
  end
  local apps = call(LOCAL, "client.list", { kinds = { "app" } }).clients or {}
  local last_err = "no Rex app is connected"
  for _, c in ipairs(apps) do
    local _, err = rex.call("client.perform", {
      client_id = c.client_id,
      action = "session.select",
      args = select_args,
      origin = ctx.origin,
    })
    if err == nil then return end
    last_err = tostring(err)
  end
  error("tab picker: switching tab: " .. last_err, 0)
end

function M.go(ctx, target)
  local session_id, window_id = target:match("^(%S+)%s*(%S*)$")
  if session_id == nil then error("tab picker: bad target: " .. target, 0) end
  local select_args = { session_id = session_id }
  if window_id ~= "" then select_args.window_id = window_id end
  show(ctx, select_args)
end

function M.setup(opts)
  for k, v in pairs(opts or {}) do
    if M.options[k] == nil then error("tab picker: unknown option " .. tostring(k), 0) end
    M.options[k] = v
  end
  if not SCOPES[M.options.scope] then
    error("tab picker: scope must be \"session\" or \"all\", not " .. tostring(M.options.scope), 0)
  end

  rex.action{
    name = "tab_picker",
    title = "Switch Tab…",
    category = "Tab",
    keywords = "tab window picker switcher fzf remote",
    args = {
      type = "object",
      properties = {
        scope = { type = "string", enum = { "session", "all" } },
        headers = { type = "boolean" },
        remote = { type = "boolean" },
      },
      additionalProperties = false,
    },
    run = function(ctx, args) M.open(ctx, args) end,
  }

  rex.action{
    name = "tab_picker_go",
    title = "Go to Tab",
    category = "Tab",
    args = { target = "string" },
    run = function(ctx, args) M.go(ctx, args.target) end,
  }

  return M
end

return M
