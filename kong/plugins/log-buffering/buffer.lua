-- Generic Logging Buffer.
--
-- Requires two objects for its use: a serializer and a sender.
--
-- The serializer needs to provide the following interface:
-- * `ok, size_or_err = serializer:add_entry(...)`
-- * `serialized, count_or_err, bytes = serializer:serialize()`
-- * `serializer:flush()`
--
-- The sender needs to provide the following interface:
-- * `ok = sender:send(serialized)`
--
-- When that serializer is full, the buffer flushes
-- its serialized data into a sending queue (FILO). The
-- sending_queue cannot exceed a given size, to avoid side effects on the
-- LuaJIT VM. If the sending_queue is full, the data is discarded.
-- If no entries have been added to the serializer in the last 'N'
-- seconds (configurable), it is flushed regardless if full or not,
-- and also queued for sending.
--
-- Once the sending_queue has elements, it tries to send the oldest one to
-- using the sender in a timer (to be called from log_by_lua). That
-- timer will keep calling itself as long as the sending_queue isn't empty.
--
-- If the data could not be sent, it can be tried again later (depending on the
-- error). If so, it is added back at the end of the sending queue. Data
-- can only be tried 'N' times, afterwards it is discarded.
--
-- Each nginx worker gets its own retry delays, stored at the chunk level of
-- this module. If the sender fails sending, the retry delay is
-- increased by n_try^2, up to 60s.


local setmetatable = setmetatable
local timer_at = ngx.timer.at
local remove = table.remove
local type = type
local huge = math.huge
local fmt = string.format
local min = math.min
local pow = math.pow
local now = ngx.now
local ERR = ngx.ERR
local DEBUG = ngx.DEBUG
local WARN = ngx.WARN

local BUFFER_MAX_SIZE_MB = 200
local BUFFER_MAX_SIZE_BYTES = BUFFER_MAX_SIZE_MB * 2^20

-- per-worker retry policy
-- simply increment the delay by n_try^2
local retry_delays = {}

-- max delay of 60s
local RETRY_MAX_DELAY = 60

local buffer = {}

local buffer_mt = {
  __index = buffer
}

local function get_now()
  return now()*1000
end

local delayed_flush
local run_sender

local function create_delayed_timer(self)
  local ok, err = timer_at(self.flush_timeout/1000, delayed_flush, self)
  if not ok then
    self.log(ERR, "failed to create delayed flush timer: ", err)
  else
    --log(DEBUG, "delayed timer created")
    self.timer_flush_pending = true
  end
end

local function create_send_timer(self, to_send, delay)
  delay = delay or 1
  local ok, err = timer_at(delay, run_sender, self, to_send)
  if not ok then
    self.log(ERR, "failed to create send timer: ", err)
  else
    self.timer_send_pending = true
  end
end

-----------------
-- Timer handlers
-----------------

delayed_flush = function(premature, self)
  if premature then return
  elseif get_now() - self.last_t < self.flush_timeout then
    -- flushing reported: we had activity
    self.log(DEBUG, "[delayed flushing handler] buffer had activity, ",
               "delaying flush")
    create_delayed_timer(self)
  else
    -- no activity and timeout reached
    self.log(DEBUG, "[delayed flushing handler] buffer had no activity, flushing ",
               "triggered by flush_timeout")
    self:flush()
    self.timer_flush_pending = false
  end
end

run_sender = function(premature, self, to_send)
  if premature then
    return
  end

  local was_sent = self.sender:send(to_send.payload)

  local next_retry_delay = 1

  if was_sent then
    -- Success!
    -- data was sent or discarded
    retry_delays[self.id] = 1 -- reset our retry policy
    self.sending_queue_size = self.sending_queue_size - to_send.bytes
  else
    -- log server could not be reached, must retry
    retry_delays[self.id] = (retry_delays[self.id] or 1) + 1
    next_retry_delay = min(RETRY_MAX_DELAY, pow(retry_delays[self.id], 2))

    self.log(WARN, "could not reach log server, retrying in: ", next_retry_delay)

    to_send.retries = to_send.retries + 1
    if to_send.retries < self.retry_count then
      -- add our data back to the sending queue, but at the
      -- end of it.
      self.sending_queue[#self.sending_queue+1] = to_send
    else
      self.log(WARN, fmt("data was already tried %d times, dropping it", to_send.retries))
    end
  end

  if #self.sending_queue > 0 then -- more to send?
    -- pop the oldest from the sending_queue
    self.log(DEBUG, fmt("sending oldest data, %d still queued", #self.sending_queue-1))
    create_send_timer(self, remove(self.sending_queue, 1), next_retry_delay)
  else
    -- we finished flushing the sending_queue, allow the creation
    -- of a future timer once the current data reached its limit
    -- and we trigger a flush()
    self.timer_send_pending = false
  end
end

---------
-- Buffer
---------

function buffer.new(id, conf, serializer, sender, log)
  if type(id) ~= "string" then
    return nil, "arg #1 (id) must be a string"
  end

  if type(conf) ~= "table" then
    return nil, "arg #2 (conf) must be a table"
  elseif conf.retry_count ~= nil and type(conf.retry_count) ~= "number" then
    return nil, "retry_count must be a number"
  elseif conf.flush_timeout ~= nil and type(conf.flush_timeout) ~= "number" then
    return nil, "flush_timeout must be a number"
  elseif conf.queue_size ~= nil and type(conf.queue_size) ~= "number" then
    return nil, "queue_size must be a number"
  elseif conf.send_delay ~= nil and type(conf.queue_size) ~= "number" then
    return nil, "send_delay must be a number"
  end

  if type(serializer) ~= "table" then
    return nil, "arg #3 (serializer) must be a table"
  elseif type(serializer.add_entry) ~= "function" then
    return nil, "arg #3 (serializer) must include an add_entry function"
  elseif type(serializer.serialize) ~= "function" then
    return nil, "arg #3 (serializer) must include a serialize function"
  elseif type(serializer.reset) ~= "function" then
    return nil, "arg #3 (serializer) must include a reset function"
  end

  if type(sender) ~= "table" then
    return nil, "arg #4 (sender) must be a table"
  elseif type(sender.send) ~= "function" then
    return nil, "arg #4 (sender) must include a send function"
  end

  if type(log) ~= "function" then
    return nil, "arg #5 (log) must be a function"
  end

  local self = {
    id = id,
    flush_timeout = conf.flush_timeout and conf.flush_timeout * 1000 or 2000, -- ms
    retry_count = conf.retry_count or 0,
    queue_size = conf.queue_size or 1000,
    send_delay = conf.send_delay or 1,

    sending_queue = {}, -- FILO queue
    sending_queue_size = 0,

    timer_flush_pending = false,
    timer_send_pending = false,

    serializer = serializer,
    sender = sender,
    log = log,

    last_t = huge,
  }

  return setmetatable(self, buffer_mt)
end

function buffer:add_entry(...)
  local ok, size_or_err = self.serializer:add_entry(...)
  if not ok then
    self.log(ERR, "could not add entry: ", size_or_err)
    return ok, size_or_err
  end

  if size_or_err >= self.queue_size then -- err is the queue size in this case
    local err
    ok, err = self:flush()
    if not ok then
      -- for our tests only
      return nil, err
    end
  elseif not self.timer_flush_pending then -- start delayed timer if none
    create_delayed_timer(self)
  end

  self.last_t = get_now()

  return true
end

function buffer:flush()
  local serialized, count_or_err, bytes = self.serializer:serialize()

  self.serializer:reset()

  if not serialized then
    self.log(ERR, "could not serialize entries: ", count_or_err)
    return nil, count_or_err
  elseif self.sending_queue_size + bytes > BUFFER_MAX_SIZE_BYTES then
    self.log(WARN, "buffer is full, discarding ", count_or_err, " entries")
    return nil, "buffer full"
  end

  self.log(DEBUG, "flushing entries for sending (", count_or_err, " entries)")

  if count_or_err > 0 then
    self.sending_queue_size = self.sending_queue_size + bytes
    self.sending_queue[#self.sending_queue + 1] = {
      payload = serialized,
      bytes = bytes,
      retries = 0
    }
  end

  -- let's try to send. we might be sending older entries with
  -- this call, but that is fine, because as long as the sending_queue
  -- has elements, 'send()' will keep trying to flush it.
  self:send()

  return true
end

function buffer:send()
  if #self.sending_queue < 1 then
    return nil, "empty queue"
  end

  -- only allow a single pending timer to send entries at a time
  -- this timer will keep calling itself while it has payloads
  -- to send.
  if not self.timer_send_pending then
    -- pop the oldest entry from the queue
    self.log(DEBUG, fmt("sending oldest entry, %d still queued", #self.sending_queue-1))
    create_send_timer(self, remove(self.sending_queue, 1), self.send_delay)
  end
end

return buffer
