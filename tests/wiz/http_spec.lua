local http = require("wiz.http")

local function wait_for(get)
  assert(vim.wait(1000, function()
    return get() ~= nil
  end, 5))
end

describe("wiz.http", function()
  local calls, next_result
  local orig = http._system

  before_each(function()
    calls = {}
    next_result = { code = 0, stdout = '{"ok":true}\n200', stderr = "" }
    http._system = function(cmd, opts, on_exit)
      table.insert(calls, { cmd = cmd, opts = opts })
      on_exit(next_result)
      return { kill = function() end }
    end
  end)

  after_each(function()
    http._system = orig
  end)

  it("url-encodes", function()
    assert.equals("a%20b%26c%3D%2F", http.urlencode("a b&c=/"))
  end)

  it("post_form sends fields on stdin, never in argv", function()
    local res
    http.post_form(
      "https://auth.example/oauth/token",
      { client_secret = "s3cr3t", grant_type = "x" },
      {},
      function(err, r)
        res = { err = err, r = r }
      end
    )
    wait_for(function()
      return res
    end)
    local call = calls[1]
    for _, a in ipairs(call.cmd) do
      assert.is_nil(a:find("s3cr3t", 1, true))
    end
    assert.truthy(vim.tbl_contains(call.cmd, "@-"))
    assert.equals("client_secret=s3cr3t&grant_type=x", call.opts.stdin)
    assert.is_nil(res.err)
    assert.equals(200, res.r.status)
    assert.is_true(res.r.body.ok)
  end)

  it("post_json passes the bearer token via stdin config and the body via a temp file", function()
    local res, body_path
    http._system = function(cmd, opts, on_exit)
      table.insert(calls, { cmd = cmd, opts = opts })
      for i, a in ipairs(cmd) do
        if a == "--data-binary" then
          body_path = cmd[i + 1]:sub(2)
        end
      end
      assert.equals('{"query":"q"}', table.concat(vim.fn.readfile(body_path), "\n"))
      on_exit(next_result)
      return { kill = function() end }
    end
    http.post_json("https://api.example/graphql", { query = "q" }, { bearer = "tok123" }, function(err, r)
      res = { err = err, r = r }
    end)
    wait_for(function()
      return res
    end)
    local call = calls[1]
    for _, a in ipairs(call.cmd) do
      assert.is_nil(a:find("tok123", 1, true))
    end
    assert.truthy(call.opts.stdin:find('header = "Authorization: Bearer tok123"', 1, true))
    assert.equals(0, vim.fn.filereadable(body_path), "temp body file should be deleted")
    assert.is_nil(res.err)
  end)

  it("maps non-2xx to a redacted http error", function()
    next_result = { code = 0, stdout = '{"error":"bad Bearer abc"}\n401', stderr = "" }
    local res
    http.post_form("https://x.example", {}, {}, function(err)
      res = err
    end)
    wait_for(function()
      return res
    end)
    assert.equals("http", res.kind)
    assert.equals(401, res.status)
    assert.is_nil(res.message:find("abc", 1, true))
  end)

  it("maps curl failures to network errors", function()
    next_result = { code = 6, stdout = "", stderr = "curl: (6) Could not resolve host" }
    local res
    http.post_form("https://x.example", {}, {}, function(err)
      res = err
    end)
    wait_for(function()
      return res
    end)
    assert.equals("network", res.kind)
    assert.truthy(res.message:find("resolve", 1, true))
  end)

  it("maps invalid JSON to a decode error", function()
    next_result = { code = 0, stdout = "<html>\n200", stderr = "" }
    local res
    http.post_form("https://x.example", {}, {}, function(err)
      res = err
    end)
    wait_for(function()
      return res
    end)
    assert.equals("decode", res.kind)
  end)

  it("passes the timeout to vim.system", function()
    local done
    http.post_form("https://x.example", {}, { timeout_ms = 1234 }, function()
      done = true
    end)
    wait_for(function()
      return done
    end)
    assert.equals(1234, calls[1].opts.timeout)
  end)
end)
