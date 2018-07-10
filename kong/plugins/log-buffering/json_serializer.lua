-- JSON array serializer object for using the Generic Logging Buffer.
local cjson = require("cjson")


local json_serializer = {}


local cjson_encode = cjson.encode


local function add_entry(self, data)
  if not self.encoded then
    data = cjson_encode(data)
  end
  local n = #self.buffer
  if n == 0 then
    self.buffer[1] = "["
  else
    self.buffer[n+1] = ","
  end
  self.buffer[n+2] = data
  self.bytes = self.bytes + #data + 1
  return true, (n + 2) / 2
end


local function serialize(self)
  local count = #self.buffer / 2
  self.buffer[#self.buffer + 1] = "]"
  local data = table.concat(self.buffer)
  return data, count, #data
end


local function reset(self)
  self.buffer = {}
  self.bytes = 1
end


-- Serializes the given entries into a JSON array.
-- @param raw_tree (boolean)
-- If `encoded` is `true`, entries are assumed to be strings
-- that already represent JSON-encoded data.
-- If `encoded` is `false`, entries are assumed to be Lua objects
-- that need to be encoded during serialization.
function json_serializer.new(encoded)
  if encoded ~= nil and type(encoded) ~= "boolean" then
    error("arg 2 (encoded) must be boolean")
  end

  local self = {
    buffer = {},
    bytes = 1,
    encoded = encoded,

    add_entry = add_entry,
    serialize = serialize,
    reset = reset,
  }

  return self
end


return json_serializer
