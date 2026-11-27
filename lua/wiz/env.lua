---@mod wiz.env Read Wiz credentials from environment variables.
--- Values are never logged; only variable *names* are reported.
local M = {}

M.DEFAULT_AUTH_URL = "https://auth.app.wiz.io/oauth/token"
M.DEFAULT_AUDIENCE = "wiz-api"

local REQUIRED = { "client_id", "client_secret", "api_endpoint" }

---@param name string
---@return string?
M._getenv = function(name)
  return vim.env[name]
end

local function names()
  return require("wiz.config").get().env
end

---@class wiz.Credentials
---@field client_id string
---@field client_secret string
---@field api_endpoint string
---@field auth_url string
---@field audience string

---@return wiz.Credentials?, string[]?
function M.read()
  local vars = names()
  local v = {}
  for key, var in pairs(vars) do
    local value = M._getenv(var)
    if value ~= nil and value ~= "" then
      v[key] = value
    end
  end

  local missing = {}
  for _, key in ipairs(REQUIRED) do
    if not v[key] then
      table.insert(missing, vars[key])
    end
  end
  if #missing > 0 then
    return nil, missing
  end

  if not v.api_endpoint:match("^https://") then
    return nil, { vars.api_endpoint .. " (must start with https://)" }
  end
  if not v.api_endpoint:match("/graphql/?$") then
    v.api_endpoint = v.api_endpoint:gsub("/+$", "") .. "/graphql"
  end
  v.auth_url = v.auth_url or M.DEFAULT_AUTH_URL
  v.audience = v.audience or M.DEFAULT_AUDIENCE
  return v
end

--- Which variables are set (name -> boolean). Safe to display.
---@return table<string, boolean>
function M.status()
  local out = {}
  for _, var in pairs(names()) do
    local value = M._getenv(var)
    out[var] = value ~= nil and value ~= ""
  end
  return out
end

return M
