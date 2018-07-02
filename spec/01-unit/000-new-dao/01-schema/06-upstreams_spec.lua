local Schema = require "kong.db.schema"
local upstreams = require "kong.db.schema.entities.upstreams"


local Upstreams = Schema.new(upstreams)

local function validate(b)
  return Upstreams:validate(Upstreams:process_auto_fields(b, "insert"))
end


describe("load upstreams", function()
  local a_valid_uuid = "cbb297c0-a956-486d-ad1d-f9b42df9465a"
  local uuid_pattern = "^" .. ("%x"):rep(8) .. "%-" .. ("%x"):rep(4) .. "%-"
                           .. ("%x"):rep(4) .. "%-" .. ("%x"):rep(4) .. "%-"
                           .. ("%x"):rep(12) .. "$"


  it("validates a valid load upstream", function()
    local u = {
      id              = a_valid_uuid,
      name            = "my_service",
      hash_on         = "header",
      hash_on_header  = "X-Balance",
      hash_fallback   = "cookie",
      hash_on_cookie  = "a_cookie",
    }
    assert(validate(u))
  end)

  it("invalid name produces error", function()
    local ok, errs = validate({ name = "1234" })
    assert.falsy(ok)
    assert.truthy(errs["name"])

    ok, errs = validate({ name = "fafa fafa" })
    assert.falsy(ok)
    assert.truthy(errs["name"])

    ok, errs = validate({ name = "192.168.0.1" })
    assert.falsy(ok)
    assert.truthy(errs["name"])

    ok, errs = validate({ name = "myserver:8000" })
    assert.falsy(ok)
    assert.truthy(errs["name"])
  end)

  it("invalid hash_on_cookie produces error", function()
    local ok, errs = validate({ hash_on_cookie = "a cookie" })
    assert.falsy(ok)
    assert.truthy(errs["hash_on_cookie"])
  end)

  it("invalid healthckecks.active.timeout produces error", function()
    local ok, errs = validate({ healthchecks = { active = { timeout = -1 } } } )
    assert.falsy(ok)
    assert.truthy(errs.healthchecks.active.timeout)
  end)

  it("invalid healthckecks.active.concurrency produces error", function()
    local ok, errs = validate({ healthchecks = { active = { concurrency = -1 } } } )
    assert.falsy(ok)
    assert.truthy(errs.healthchecks.active.concurrency)
  end)

  it("invalid healthckecks.active.http_path produces error", function()
    local ok, errs = validate({ healthchecks = { active = { http_path = "potato" } } } )
    assert.falsy(ok)
    assert.truthy(errs.healthchecks.active.http_path)
  end)

  it("invalid healthckecks.active.healthy.interval produces error", function()
    local ok, errs = validate({ healthchecks = { active = { healthy = { interval = -1 } } } } )
    assert.falsy(ok)
    assert.truthy(errs.healthchecks.active.healthy.interval)
  end)

  it("invalid healthckecks.active.healthy.successes produces error", function()
    local ok, errs = validate({ healthchecks = { active = { healthy = { successes = -1 } } } } )
    assert.falsy(ok)
    assert.truthy(errs.healthchecks.active.healthy.successes)
  end)

  it("invalid healthckecks.active.healthy.http_statuses produces error", function()
    local ok, errs = validate({ healthchecks = { active = { healthy = { http_statuses = "potato" } } } } )
    assert.falsy(ok)
    assert.truthy(errs.healthchecks.active.healthy.http_statuses)
  end)

  -- not testing active.unhealthy.* and passive.*.* since they are defined like healthy.*.*

  it("hash_on = 'header' makes hash_on_header required", function()
    local ok, errs = validate({ hash_on = "header" })
    assert.falsy(ok)
    assert.truthy(errs.hash_on_header)
  end)

  it("hash_fallback = 'header' makes hash_fallback_header required", function()
    local ok, errs = validate({ hash_fallback = "header" })
    assert.falsy(ok)
    assert.truthy(errs.hash_fallback_header)
  end)

  it("hash_on = 'cookie' makes hash_on_cookie required", function()
    local ok, errs = validate({ hash_on = "cookie" })
    assert.falsy(ok)
    assert.truthy(errs.hash_on_cookie)
  end)

  it("hash_on = 'cookie' makes hash_on_cookie required", function()
    local ok, errs = validate({ hash_fallback = "cookie" })
    assert.falsy(ok)
    assert.truthy(errs.hash_on_cookie)
  end)

  it("hash_on = 'none' requires that hash_fallback is also none", function()
    local ok, errs = validate({ hash_on = "none", hash_fallback = "header" })
    assert.falsy(ok)
    assert.truthy(errs.hash_fallback)
  end)

  it("hash_on = 'cookie' requires that hash_fallback is also none", function()
    local ok, errs = validate({ hash_on = "cookie", hash_fallback = "header" })
    assert.falsy(ok)
    assert.truthy(errs.hash_fallback)
  end)

  it("hash_on must be different from hash_fallback", function()
    local ok, errs = validate({ hash_on = "consumer", hash_fallback = "consumer" })
    assert.falsy(ok)
    assert.truthy(errs.hash_fallback)
    ok, errs = validate({ hash_on = "ip", hash_fallback = "ip" })
    assert.falsy(ok)
    assert.truthy(errs.hash_fallback)
  end)

  it("produces defaults", function()
    local u = {
      name = "www.example.com",
    }
    u = Upstreams:process_auto_fields(u, "insert")
    local ok, err = Upstreams:validate(u)
    assert.truthy(ok)
    assert.is_nil(err)
    assert.match(uuid_pattern, u.id)
    assert.same(u.name, "www.example.com")
    assert.same(u.hash_on, "none")
    assert.same(u.hash_fallback, "none")
    assert.same(u.hash_on_cookie_path, "/")
    assert.same(u.slots, 10000)
    assert.same(u.healthchecks, {
      active = {
        timeout = 1,
        concurrency = 10,
        http_path = "/",
        healthy = {
          interval = 0,
          http_statuses = { 200, 302 },
          successes = 0,
        },
        unhealthy = {
          interval = 0,
          http_statuses = { 429, 404,
                            500, 501, 502, 503, 504, 505 },
          tcp_failures = 0,
          timeouts = 0,
          http_failures = 0,
        },
      },
      passive = {
        healthy = {
          http_statuses = { 200, 201, 202, 203, 204, 205, 206, 207, 208, 226,
                            300, 301, 302, 303, 304, 305, 306, 307, 308 },
          successes = 0,
        },
        unhealthy = {
          http_statuses = { 429, 500, 503 },
          tcp_failures = 0,
          timeouts = 0,
          http_failures = 0,
        },
      },
    })
  end)

--[[

  describe("path attribute", function()
    -- refusals
    it("must be a string", function()
      local service = {
        path = false,
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("expected a string", err.path)
    end)

    it("must be a non-empty string", function()
      local service = {
        path = "",
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("length must be at least 1", err.path)
    end)

    it("must start with /", function()
      local service = {
        path = "foo",
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("should start with: /", err.path)
    end)

    it("must not have empty segments (/foo//bar)", function()
      local invalid_paths = {
        "/foo//bar",
        "/foo/bar//",
        "//foo/bar",
      }

      for i = 1, #invalid_paths do
        local service = {
          path = invalid_paths[i],
        }

        local ok, err = Services:validate(service)
        assert.falsy(ok)
        assert.equal("must not have empty segments", err.path)
      end
    end)

    it("rejects badly percent-encoded values", function()
      local invalid_paths = {
        "/some%2words",
        "/some%0Xwords",
        "/some%2Gwords",
        "/some%20words%",
        "/some%20words%a",
        "/some%20words%ax",
      }

      local errstr = { "%2w", "%0X", "%2G", "%", "%a", "%ax" }

      for i = 1, #invalid_paths do
        local service = {
          path = invalid_paths[i],
        }

        local ok, err = Services:validate(service)
        assert.falsy(ok)
        assert.matches("invalid url-encoded value: '" .. errstr[i] .. "'",
                       err.path, nil, true)
      end
    end)

    -- acceptance
    it("accepts an apex '/'", function()
      local service = {
        protocol = "http",
        host = "example.com",
        path = "/",
        port = 80,
      }

      local ok, err = Services:validate(service)
      assert.is_nil(err)
      assert.is_true(ok)
    end)

    it("accepts unreserved characters from RFC 3986", function()
      local service = {
        protocol = "http",
        host = "example.com",
        path = "/abcd~user~2",
        port = 80,
      }

      local ok, err = Services:validate(service)
      assert.is_nil(err)
      assert.is_true(ok)
    end)

    it("accepts properly percent-encoded values", function()
      local valid_paths = { "/abcd%aa%10%ff%AA%FF" }

      for i = 1, #valid_paths do
        local service = {
          protocol = "http",
          host = "example.com",
          path = valid_paths[i],
          port = 80,
        }

        local ok, err = Services:validate(service)
        assert.is_nil(err)
        assert.is_true(ok)
      end
    end)

    it("accepts trailing slash", function()
      local service = {
        protocol = "http",
        host = "example.com",
        path = "/ovo/",
        port = 80,
      }

      local ok, err = Services:validate(service)
      assert.is_true(ok)
      assert.is_nil(err)
    end)
  end)

  describe("host attribute", function()
    -- refusals
    it("must be a string", function()
      local service = {
        host = false,
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("expected a string", err.host)
    end)

    it("must be a non-empty string", function()
      local service = {
        host = "",
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("length must be at least 1", err.host)
    end)

    it("rejects invalid hostnames", function()
      local invalid_hosts = {
        "/example",
        ".example",
        "example.",
        "example:",
        "mock;bin",
        "example.com/org",
        "example-.org",
        "example.org-",
        "hello..example.com",
        "hello-.example.com",
        "*example.com",
        "www.example*",
        "mock*bin.com",
      }

      for i = 1, #invalid_hosts do
        local service = {
          host = invalid_hosts[i],
        }

        local ok, err = Services:validate(service)
        assert.falsy(ok)
        assert.equal("invalid value: " .. invalid_hosts[i], err.host)
      end
    end)

    it("rejects values with a valid port", function()
      local service = {
        host = "example.com:80",
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("must not have a port", err.host)
    end)

    it("rejects values with an invalid port", function()
      local service = {
        host = "example.com:1000000",
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("must not have a port", err.host)
    end)

    -- acceptance
    it("accepts valid hosts", function()
      local valid_hosts = {
        "hello.com",
        "hello.fr",
        "test.hello.com",
        "1991.io",
        "hello.COM",
        "HELLO.com",
        "123helloWORLD.com",
        "example.123",
        "example-api.com",
        "hello.abcd",
        "example_api.com",
        "localhost",
        -- below:
        -- punycode examples from RFC3492;
        -- https://tools.ietf.org/html/rfc3492#page-14
        -- specifically the japanese ones as they mix
        -- ascii with escaped characters
        "3B-ww4c5e180e575a65lsy2b",
        "-with-SUPER-MONKEYS-pc58ag80a8qai00g7n9n",
        "Hello-Another-Way--fc4qua05auwb3674vfr0b",
        "2-u9tlzr9756bt3uc0v",
        "MajiKoi5-783gue6qz075azm5e",
        "de-jg4avhby1noc0d",
        "d9juau41awczczp",
      }

      for i = 1, #valid_hosts do
        local service = {
          protocol = "http",
          host = valid_hosts[i],
          port = 80,
        }

        local ok, err = Services:validate(service)
        assert.is_nil(err)
        assert.is_true(ok)
      end
    end)
  end)

  describe("name attribute", function()
    -- refusals
    it("must be a string", function()
      local service = {
        name = false,
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("expected a string", err.name)
    end)

    it("must be a non-empty string", function()
      local service = {
        name = "",
      }

      local ok, err = Services:validate(service)
      assert.falsy(ok)
      assert.equal("length must be at least 1", err.name)
    end)

    it("rejects invalid names", function()
      local invalid_names = {
        "examp:le",
        "examp;le",
        "examp/le",
        "examp le",
      }

      for i = 1, #invalid_names do
        local service = {
          name = invalid_names[i],
        }

        local ok, err = Services:validate(service)
        assert.falsy(ok)
        assert.equal(
          "invalid value '" .. invalid_names[i] .. "': it must only contain alphanumeric and '., -, _, ~' characters",
          err.name)
      end
    end)

    -- acceptance
    it("accepts valid names", function()
      local valid_names = {
        "example",
        "EXAMPLE",
        "exa.mp.le",
        "3x4mp13",
        "3x4-mp-13",
        "3x4_mp_13",
        "~3x4~mp~13",
        "~3..x4~.M-p~1__3_",
      }

      for i = 1, #valid_names do
        local service = {
          protocol = "http",
          host = "example.com",
          port = 80,
          name = valid_names[i]
        }

        local ok, err = Services:validate(service)
        assert.is_nil(err)
        assert.is_true(ok)
      end
    end)
  end)
]]
end)
