-- Lua array serializer object for using the Generic Logging Buffer.


local lua_serializer = {}


local function add_entry(self, data)
  table.insert(self.buffer, data)
  self.size = self.size + #data
  return true, self.size
end


local function serialize(self)
  return self.buffer, #self.buffer, self.size
end


local function reset(self)
  self.buffer = {}
  self.size = 0
end


function lua_serializer.new(conf)
  local self = {
    buffer = {},
    size = 0,

    add_entry = add_entry,
    serialize = serialize,
    reset = reset,
  }

  return self
end


return lua_serializer
