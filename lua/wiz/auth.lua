---@mod wiz.auth OAuth client-credentials token, cached in memory only.
local M = {}

local REFRESH_MARGIN_S = 300

local state = { token = nil, expires_at = 0, waiting = nil }

M._now = function()
  return os.time()
end

function M._reset()
  state = { token = nil, expires_at = 0, waiting = nil }
end

function M.invalidate()
  state.token = nil
  state.expires_at = 0
end

---@class wiz.AuthError
---@field kind "env"|"auth"|"network"|"http"|"decode"
---@field message string?
---@field missing string[]?

local function flush(err, token)
  local waiters = state.waiting or {}
  state.waiting = nil
  for _, cb in ipairs(waiters) do
    cb(err, token)
  end
end

--- Get a valid bearer token, fetching one if needed.
---@param cb fun(err: wiz.AuthError?, token: string?)
function M.token(cb)
  if state.token and M._now() < state.expires_at - REFRESH_MARGIN_S then
    return cb(nil, state.token)
  end
  if state.waiting then
    table.insert(state.waiting, cb)
    return
  end

  local creds, missing = require("wiz.env").read()
  if not creds then
    return cb({
      kind = "env",
      missing = missing,
      message = "missing or invalid environment variables: " .. table.concat(missing or {}, ", "),
    })
  end

  state.waiting = { cb }
  require("wiz.http").post_form(creds.auth_url, {
    grant_type = "client_credentials",
    client_id = creds.client_id,
    client_secret = creds.client_secret,
    audience = creds.audience,
  }, {}, function(err, res)
    if err then
      if err.status == 400 or err.status == 401 or err.status == 403 then
        err = {
          kind = "auth",
          status = err.status,
          message = "Wiz rejected the credentials (HTTP "
            .. err.status
            .. "). Check WIZ_CLIENT_ID / WIZ_CLIENT_SECRET, WIZ_AUTH_URL and the service account's scopes.",
        }
      end
      return flush(err)
    end
    local body = res and res.body or {}
    if type(body.access_token) ~= "string" or body.access_token == "" then
      return flush({ kind = "auth", message = "token response did not include an access_token" })
    end
    state.token = body.access_token
    state.expires_at = M._now() + (tonumber(body.expires_in) or 3600)
    flush(nil, state.token)
  end)
end

return M
