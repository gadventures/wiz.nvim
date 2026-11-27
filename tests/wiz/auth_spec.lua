local auth = require("wiz.auth")
local env = require("wiz.env")
local http = require("wiz.http")
local config = require("wiz.config")

describe("wiz.auth", function()
  local orig_post, orig_getenv, orig_now
  local posts, pending, now

  before_each(function()
    config.setup({})
    auth._reset()
    posts, pending, now = {}, {}, 1000
    orig_post, orig_getenv, orig_now = http.post_form, env._getenv, auth._now
    env._getenv = function(name)
      return ({
        WIZ_CLIENT_ID = "id",
        WIZ_CLIENT_SECRET = "secret",
        WIZ_API_ENDPOINT = "https://api.example/graphql",
      })[name]
    end
    auth._now = function()
      return now
    end
    http.post_form = function(url, fields, _, cb)
      table.insert(posts, { url = url, fields = fields })
      table.insert(pending, cb)
    end
  end)

  after_each(function()
    http.post_form, env._getenv, auth._now = orig_post, orig_getenv, orig_now
  end)

  local function respond(i, err, res)
    pending[i](err, res)
  end

  it("requests a client-credentials token", function()
    local got
    auth.token(function(err, tok)
      got = { err = err, tok = tok }
    end)
    assert.equals(1, #posts)
    assert.equals("https://auth.app.wiz.io/oauth/token", posts[1].url)
    assert.same(
      { grant_type = "client_credentials", client_id = "id", client_secret = "secret", audience = "wiz-api" },
      posts[1].fields
    )
    respond(1, nil, { status = 200, body = { access_token = "T1", expires_in = 3600 } })
    assert.same({ tok = "T1" }, { tok = got.tok })
    assert.is_nil(got.err)
  end)

  it("caches the token until 5 minutes before expiry", function()
    auth.token(function() end)
    respond(1, nil, { status = 200, body = { access_token = "T1", expires_in = 3600 } })
    local tok
    now = 1000 + 3600 - 301
    auth.token(function(_, t)
      tok = t
    end)
    assert.equals("T1", tok)
    assert.equals(1, #posts)
    now = 1000 + 3600 - 299
    auth.token(function() end)
    assert.equals(2, #posts)
  end)

  it("invalidate forces a refresh", function()
    auth.token(function() end)
    respond(1, nil, { status = 200, body = { access_token = "T1", expires_in = 3600 } })
    auth.invalidate()
    auth.token(function() end)
    assert.equals(2, #posts)
  end)

  it("shares one in-flight request between concurrent callers", function()
    local a, b
    auth.token(function(_, t)
      a = t
    end)
    auth.token(function(_, t)
      b = t
    end)
    assert.equals(1, #posts)
    respond(1, nil, { status = 200, body = { access_token = "T1", expires_in = 3600 } })
    assert.equals("T1", a)
    assert.equals("T1", b)
  end)

  it("reports missing env vars without calling the endpoint", function()
    env._getenv = function()
      return nil
    end
    local err
    auth.token(function(e)
      err = e
    end)
    assert.equals(0, #posts)
    assert.equals("env", err.kind)
    assert.truthy(vim.tbl_contains(err.missing, "WIZ_CLIENT_SECRET"))
  end)

  it("maps 401/403 to auth errors", function()
    local err
    auth.token(function(e)
      err = e
    end)
    respond(1, { kind = "http", status = 401, message = "unauthorized" })
    assert.equals("auth", err.kind)
  end)

  it("rejects responses without an access_token", function()
    local err
    auth.token(function(e)
      err = e
    end)
    respond(1, nil, { status = 200, body = {} })
    assert.equals("auth", err.kind)
  end)
end)
