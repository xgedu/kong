-- Serializer object for using the Generic Logging Buffer.


local alf_serializer = require "kong.plugins.galileo.alf"


local serializer = {}


local function add_entry(self, ...)
  return self.cur_alf:add_entry(...)
end


local function serialize(self)
  local serialized, count_or_err = self.cur_alf:serialize(self.service_token, self.environment)
  if serialized then
    return serialized, count_or_err, #serialized
  end
  return nil, count_or_err
end


local function reset(self)
  return self.cur_alf:reset()
end


function serializer.new(conf)
  if type(conf) ~= "table" then
    return nil, "arg #1 (conf) must be a table"
  elseif type(conf.service_token) ~= "string" then
    return nil, "service_token must be a string"
  elseif type(conf.server_addr) ~= "string" then
    return nil, "server_addr must be a string"
  elseif conf.log_bodies ~= nil and type (conf.log_bodies) ~= "boolean" then
    return nil, "log_bodies must be a boolean"
  elseif conf.environment ~= nil and type(conf.environment) ~= "string" then
    return nil, "environment must be a string"
  end

  local self = {
    service_token = conf.service_token,
    environment = conf.environment,

    cur_alf = alf_serializer.new(conf.log_bodies or false, conf.server_addr),

    add_entry = add_entry,
    serialize = serialize,
    reset = reset,
  }

  return self
end


return serializer
