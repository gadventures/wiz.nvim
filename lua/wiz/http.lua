---@mod wiz.http Minimal async HTTP over curl.
--- Secrets (form bodies, bearer tokens) are passed on stdin, never in argv,
--- so they don't show up in `ps` output.
local redact = require("wiz.redact")

local M = {}

---@diagnostic disable-next-line: unused-local
M._system = function(cmd, opts, on_exit)
  return vim.system(cmd, opts, on_exit)
end

---@param s any
---@return string
function M.urlencode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

---@param fields table<string, any>
---@return string
function M.encode_form(fields)
  local keys = vim.tbl_keys(fields)
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    table.insert(parts, M.urlencode(k) .. "=" .. M.urlencode(fields[k]))
  end
  return table.concat(parts, "&")
end

local function curl_path()
  local ok, config = pcall(require, "wiz.config")
  return ok and config.get().curl_path or "curl"
end

local function default_timeout()
  local ok, config = pcall(require, "wiz.config")
  return ok and config.get().http_timeout_ms or 30000
end

local function base_cmd(url, timeout_ms)
  return {
    curl_path(),
    "-sS",
    "-X",
    "POST",
    "--max-time",
    tostring(math.max(1, math.ceil(timeout_ms / 1000))),
    "-w",
    "\n%{http_code}",
    url,
  }
end

---@class wiz.HttpError
---@field kind "network"|"http"|"decode"
---@field status integer?
---@field message string

---@param res vim.SystemCompleted
---@param cb fun(err: wiz.HttpError?, res: {status: integer, body: any}?)
local function finish(res, cb)
  local stdout = res.stdout or ""
  local body, status = stdout:match("^(.*)\n(%d%d%d)%s*$")
  status = tonumber(status)
  if res.code ~= 0 or not status or status == 0 then
    local msg = (res.stderr or ""):gsub("%s+$", "")
    if msg == "" then
      msg = "curl exited with code " .. tostring(res.code)
    end
    return cb({ kind = "network", message = redact.text(msg) })
  end
  local ok, decoded = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  if status < 200 or status >= 300 then
    local msg = body
    if ok and type(decoded) == "table" then
      msg = decoded.error_description or decoded.message or decoded.error or body
    end
    return cb({ kind = "http", status = status, message = redact.text(tostring(msg):sub(1, 300)) })
  end
  if not ok then
    return cb({ kind = "decode", status = status, message = "response was not valid JSON" })
  end
  cb(nil, { status = status, body = decoded })
end

---@class wiz.HttpHandle
---@field cancel fun()

local function run(cmd, stdin, timeout_ms, cb, cleanup)
  local done = vim.schedule_wrap(function(res)
    if cleanup then
      cleanup()
    end
    finish(res, cb)
  end)
  local ok, proc = pcall(M._system, cmd, { stdin = stdin, text = true, timeout = timeout_ms }, done)
  if not ok then
    if cleanup then
      cleanup()
    end
    vim.schedule(function()
      cb({ kind = "network", message = redact.text(proc) })
    end)
    return { cancel = function() end }
  end
  return {
    cancel = function()
      pcall(function()
        proc:kill(15)
      end)
    end,
  }
end

--- POST application/x-www-form-urlencoded. Body goes through stdin.
---@param url string
---@param fields table<string, any>
---@param opts {timeout_ms: integer?}?
---@param cb fun(err: wiz.HttpError?, res: {status: integer, body: any}?)
---@return wiz.HttpHandle
function M.post_form(url, fields, opts, cb)
  opts = opts or {}
  local timeout_ms = opts.timeout_ms or default_timeout()
  local cmd = base_cmd(url, timeout_ms)
  vim.list_extend(cmd, { "-H", "Content-Type: application/x-www-form-urlencoded", "--data-binary", "@-" })
  return run(cmd, M.encode_form(fields), timeout_ms, cb)
end

local function config_quote(s)
  return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

--- POST JSON. The bearer token goes through a curl config read from stdin
--- (`-K -`); the body goes through a private temp file that is removed after.
---@param url string
---@param body table
---@param opts {bearer: string?, timeout_ms: integer?}?
---@param cb fun(err: wiz.HttpError?, res: {status: integer, body: any}?)
---@return wiz.HttpHandle
function M.post_json(url, body, opts, cb)
  opts = opts or {}
  local timeout_ms = opts.timeout_ms or default_timeout()
  local path = vim.fn.tempname()
  vim.fn.writefile({ vim.json.encode(body) }, path, "b")
  pcall(vim.uv.fs_chmod, path, tonumber("600", 8))
  local cleanup = function()
    os.remove(path)
  end

  local stdin = {}
  if opts.bearer then
    table.insert(stdin, "header = " .. config_quote("Authorization: Bearer " .. opts.bearer))
  end
  local cmd = base_cmd(url, timeout_ms)
  vim.list_extend(cmd, {
    "-H",
    "Content-Type: application/json",
    "-H",
    "Accept: application/json",
    "-K",
    "-",
    "--data-binary",
    "@" .. path,
  })
  return run(cmd, table.concat(stdin, "\n") .. "\n", timeout_ms, cb, cleanup)
end

return M
