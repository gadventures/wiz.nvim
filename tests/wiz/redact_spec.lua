local redact = require("wiz.redact")

describe("wiz.redact", function()
  it("masks bearer tokens", function()
    local out = redact.text("Authorization: Bearer abc.def-123_XYZ")
    assert.is_nil(out:find("abc.def", 1, true))
    assert.truthy(out:find("Bearer [REDACTED]", 1, true))
  end)

  it("masks client_secret in form and json bodies", function()
    assert.is_nil(redact.text("client_id=a&client_secret=s3cr3t&x=1"):find("s3cr3t", 1, true))
    assert.is_nil(redact.text('{"client_secret": "s3cr3t"}'):find("s3cr3t", 1, true))
    assert.is_nil(redact.text('{"access_token":"tok123"}'):find("tok123", 1, true))
  end)

  it("masks JWT- and AWS-key-shaped strings", function()
    local jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig_nature-x"
    assert.is_nil(redact.text("token " .. jwt):find(jwt, 1, true))
    assert.is_nil(redact.text("key AKIAABCDEFGHIJKLMNOP end"):find("AKIAABCDEFGHIJKLMNOP", 1, true))
  end)

  it("is idempotent and handles nil", function()
    local once = redact.text("Bearer abc client_secret=xyz")
    assert.equals(once, redact.text(once))
    assert.equals("", redact.text(nil))
  end)
end)
