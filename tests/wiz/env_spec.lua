local config = require("wiz.config")
local env = require("wiz.env")

describe("wiz.env", function()
  local vars
  local orig = env._getenv

  before_each(function()
    config.setup({})
    vars = {
      WIZ_CLIENT_ID = "id",
      WIZ_CLIENT_SECRET = "secret",
      WIZ_API_ENDPOINT = "https://api.us17.app.wiz.io/graphql",
    }
    env._getenv = function(name)
      return vars[name]
    end
  end)

  after_each(function()
    env._getenv = orig
  end)

  it("reads values and applies defaults", function()
    local v = assert(env.read())
    assert.equals("id", v.client_id)
    assert.equals("secret", v.client_secret)
    assert.equals("https://api.us17.app.wiz.io/graphql", v.api_endpoint)
    assert.equals("https://auth.app.wiz.io/oauth/token", v.auth_url)
    assert.equals("wiz-api", v.audience)
  end)

  it("returns missing variable names only", function()
    vars.WIZ_CLIENT_SECRET = nil
    vars.WIZ_CLIENT_ID = ""
    local v, missing = env.read()
    assert.is_nil(v)
    table.sort(missing)
    assert.same({ "WIZ_CLIENT_ID", "WIZ_CLIENT_SECRET" }, missing)
  end)

  it("appends /graphql when missing", function()
    vars.WIZ_API_ENDPOINT = "https://api.us17.app.wiz.io/"
    assert.equals("https://api.us17.app.wiz.io/graphql", env.read().api_endpoint)
  end)

  it("rejects non-https endpoints", function()
    vars.WIZ_API_ENDPOINT = "http://api.us17.app.wiz.io/graphql"
    local v, missing = env.read()
    assert.is_nil(v)
    assert.truthy(missing[1]:find("WIZ_API_ENDPOINT", 1, true))
  end)

  it("honors custom variable names and overrides", function()
    config.setup({ env = { client_id = "MY_WIZ_ID" } })
    vars.MY_WIZ_ID = "custom"
    vars.WIZ_AUTH_URL = "https://auth.gov.wiz.io/oauth/token"
    local v = assert(env.read())
    assert.equals("custom", v.client_id)
    assert.equals("https://auth.gov.wiz.io/oauth/token", v.auth_url)
  end)

  it("reports which variables are set without exposing values", function()
    local status = env.status()
    assert.is_true(status.WIZ_CLIENT_ID)
    assert.is_false(status.WIZ_AUTH_URL)
  end)
end)
