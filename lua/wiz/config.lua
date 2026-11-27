---@mod wiz.config Configuration
local M = {}

M.SEVERITIES = { "INFO", "LOW", "MEDIUM", "HIGH", "CRITICAL" }
M.SCAN_TYPES = { "iac", "secret", "vuln", "image" }
M.PICKERS = { "auto", "snacks", "fzf", "telescope", "select" }

local RANK = {}
for i, s in ipairs(M.SEVERITIES) do
  RANK[s] = i
end

---@param sev string?
---@return integer
function M.rank(sev)
  return RANK[(sev or ""):upper()] or 1
end

M.defaults = {
  wizcli_path = "wizcli",
  wizcli_args = {},
  curl_path = "curl",
  scan_types = { "iac", "secret", "vuln" },
  scan_on_save = false,
  scan_on_open = true,
  debounce_ms = 2000,
  timeout_ms = 300000,
  http_timeout_ms = 30000,
  poll = { initial_ms = 1000, max_ms = 5000 },
  min_severity = "LOW",
  env = {
    client_id = "WIZ_CLIENT_ID",
    client_secret = "WIZ_CLIENT_SECRET",
    api_endpoint = "WIZ_API_ENDPOINT",
    auth_url = "WIZ_AUTH_URL",
    audience = "WIZ_AUTH_AUDIENCE",
  },
  diagnostics = { virtual_text = true, signs = true, underline = true },
  picker = "auto",
  portal_url = "https://app.wiz.io",
  ignore_file = ".wiz-nvim-ignore.json",
  keymaps = { prefix = "<leader>z" },
}

-- Options whose values are lists: replaced wholesale, never merged by index.
local LIST_KEYS = { "scan_types", "wizcli_args" }

local current = vim.deepcopy(M.defaults)

local function fail(msg)
  error("wiz.nvim: invalid config: " .. msg, 3)
end

local function validate(c)
  if type(c.min_severity) ~= "string" or not RANK[c.min_severity:upper()] then
    fail("min_severity must be one of " .. table.concat(M.SEVERITIES, ", "))
  end
  c.min_severity = c.min_severity:upper()
  if not vim.tbl_contains(M.PICKERS, c.picker) then
    fail("picker must be one of " .. table.concat(M.PICKERS, ", "))
  end
  for _, key in ipairs({ "debounce_ms", "timeout_ms", "http_timeout_ms" }) do
    if type(c[key]) ~= "number" or c[key] < 0 then
      fail(key .. " must be a non-negative number")
    end
  end
  for _, key in ipairs({ "initial_ms", "max_ms" }) do
    if type(c.poll[key]) ~= "number" or c.poll[key] <= 0 then
      fail("poll." .. key .. " must be a positive number")
    end
  end
  if type(c.scan_types) ~= "table" then
    fail("scan_types must be a list")
  end
  for _, t in ipairs(c.scan_types) do
    if not vim.tbl_contains(M.SCAN_TYPES, t) then
      fail("unknown scan type '" .. tostring(t) .. "'")
    end
  end
  if type(c.wizcli_args) ~= "table" then
    fail("wizcli_args must be a list")
  end
  if c.keymaps ~= false and type(c.keymaps) ~= "table" then
    fail("keymaps must be a table or false")
  end
  for _, key in ipairs({ "scan_on_save", "scan_on_open" }) do
    if type(c[key]) ~= "boolean" then
      fail(key .. " must be a boolean")
    end
  end
end

---@param opts table?
---@return table
function M.setup(opts)
  opts = opts or {}
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  for _, key in ipairs(LIST_KEYS) do
    if opts[key] ~= nil then
      merged[key] = vim.deepcopy(opts[key])
    end
  end
  validate(merged)
  current = merged
  return current
end

---@return table
function M.get()
  return current
end

return M
