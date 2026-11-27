---@mod wiz.redact Scrub secrets from any text before it is shown or logged
local M = {}

local AWS_KEY = "AKIA" .. string.rep("[0-9A-Z]", 16)

local RULES = {
  { "([Bb]earer%s+)[%w%-%._~%+/=]+", "%1[REDACTED]" },
  { "(client_secret=)[^&%s]+", "%1[REDACTED]" },
  { '("client_secret"%s*:%s*")[^"]*', "%1[REDACTED]" },
  { '("access_token"%s*:%s*")[^"]*', "%1[REDACTED]" },
  { "eyJ[%w%-_]+%.[%w%-_]+%.[%w%-_]+", "[REDACTED_JWT]" },
  { AWS_KEY, "[REDACTED_AWS_KEY]" },
}

---@param s any
---@return string
function M.text(s)
  if s == nil then
    return ""
  end
  s = tostring(s)
  for _, rule in ipairs(RULES) do
    s = s:gsub(rule[1], rule[2])
  end
  return s
end

return M
