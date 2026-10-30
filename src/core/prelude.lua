-- Loaded before every script. Thin wrappers over the `koi` command line, so a
-- script can do anything the command line can, with no logic of its own to drift.
local koi = koi

-- Runs `koi ...` and returns its standard output, or raises with what it said.
local function ok(...)
  local success, out, code = koi.run(...)
  if not success then error("koi " .. tostring((...)) .. " failed (exit " .. tostring(code) .. ")", 3) end
  return out
end

local function trim(s) return (s:gsub("%s+$", "")) end

-- The server's tree of tabs and groups, decoded.
function koi.ls() return koi.json(ok("ls", "--json")) end

-- A new tab; returns its id. opts: cwd, command.
function koi.new(opts)
  opts = opts or {}
  local args = { "new" }
  if opts.cwd then args[#args + 1] = "--cwd"; args[#args + 1] = opts.cwd end
  if opts.command then args[#args + 1] = "--command"; args[#args + 1] = opts.command end
  return trim(ok(table.unpack(args)))
end

-- Splits a pane or tab; returns the new pane's id. opts: direction ("right" or "down"), cwd, command.
function koi.split(target, opts)
  opts = opts or {}
  local args = { "split", target }
  if opts.direction then args[#args + 1] = "--" .. opts.direction end
  if opts.cwd then args[#args + 1] = "--cwd"; args[#args + 1] = opts.cwd end
  if opts.command then args[#args + 1] = "--command"; args[#args + 1] = opts.command end
  return trim(ok(table.unpack(args)))
end

function koi.send(target, text) ok("send", target, text) end
function koi.capture(target) return ok("capture", target) end
function koi.close(target) ok("close", target) end
function koi.status(state) ok("status", state) end

-- Waits until `pattern` (a Lua pattern) appears in the target's screen and
-- scrollback; returns the match, or nil after `timeout` seconds (default 30).
-- Safe to call right after koi.new.
function koi.wait(target, pattern, timeout)
  local deadline = os.time() + (timeout or 30)
  repeat
    -- A pane still starting cannot be captured yet: that is "not yet", not an error.
    local good, screen = koi.run("capture", target)
    local found = good and screen:match(pattern)
    if found then return found end
    koi.sleep(0.2)
  until os.time() >= deadline
  return nil
end
