local cjson = require "cjson"
local balancer = require "kong.runloop.balancer"
local utils = require "kong.tools.utils"

local _TARGETS = {}


local function sort_by_order(a, b)
  return a.order > b.order
end

local function clean_history(upstream_pk)
  -- when to cleanup: invalid-entries > (valid-ones * cleanup_factor)
  local cleanup_factor = 10

  --cleaning up history, check if it's necessary...
  local target_history = kong.db.targets:for_upstream(upstream_pk, { include_inactive = true })

  if target_history then
    -- sort the targets
    for _,target in ipairs(target_history) do
      target.order = target.created_at .. ":" .. target.id
    end

    -- sort table in reverse order
    table.sort(target_history, function(a,b) return a.order>b.order end)
    -- do clean up
    local cleaned = {}
    local delete = {}

    for _, entry in ipairs(target_history) do
      if cleaned[entry.target] then
        -- we got a newer entry for this target than this, so this one can go
        delete[#delete+1] = entry

      else
        -- haven't got this one, so this is the last one for this target
        cleaned[entry.target] = true
        cleaned[#cleaned+1] = entry
        if entry.weight == 0 then
          delete[#delete+1] = entry
        end
      end
    end

    -- do we need to cleanup?
    -- either nothing left, or when 10x more outdated than active entries
    if (#cleaned == 0 and #delete > 0) or
       (#delete >= (math.max(#cleaned,1)*cleanup_factor)) then

      kong.log("[Target DAO] Starting cleanup of target table for upstream ",
                 tostring(upstream_pk.id))
      local cnt = 0
      for _, entry in ipairs(delete) do
        -- not sending update events, one event at the end, based on the
        -- post of the new entry should suffice to reload only once
        kong.db.targets:delete(
          { id = entry.id },
          { quiet = true }
        )
        -- ignoring errors here, deleted by id, so should not matter
        -- in case another kong-node does the same cleanup simultaneously
        cnt = cnt + 1
      end

      ngx.log(ngx.INFO, "[Target DAO] Finished cleanup of target table",
        " for upstream ", tostring(upstream_pk.id),
        " removed ", tostring(cnt), " target entries")
    end
  end
end


function _TARGETS:insert(entity)
  clean_history(entity.upstream)
  return self.super.insert(self, entity)
end


function _TARGETS:delete(pk)
  local target, err, err_t = self:select(pk)
  if err then
    return nil, err, err_t
  end

  return self:insert({
    target   = target.target,
    upstream = target.upstream,
    weight   = 0,
  })
end


function _TARGETS:for_upstream(upstream_pk, options)
  options = options or {}
  local include_inactive = options.include_inactive
  local include_health = options.include_health
  local all_targets, err, err_t = self.super.for_upstream(self, upstream_pk)
  if not all_targets then
    return nil, err, err_t
  end
  if include_inactive then
    return all_targets
  end

  -- sort and walk based on target and creation time
  for _, target in ipairs(all_targets) do
    target.order = ("%s:%d:%s"):format(target.target,
                                       target.created_at,
                                       target.id)
  end
  table.sort(all_targets, sort_by_order)

  local seen           = {}
  local active_targets = setmetatable({}, cjson.empty_array_mt)
  local len            = 0

  for _, entry in ipairs(all_targets) do
    if not seen[entry.target] then
      if entry.weight == 0 then
        seen[entry.target] = true

      else
        entry.order = nil -- dont show our order key to the client

        -- add what we want to send to the client in our array
        len = len + 1
        active_targets[len] = entry

        -- track that we found this host:port so we only show
        -- the most recent one (kinda)
        seen[entry.target] = true
      end
    end
  end

  if not include_health then
    return active_targets
  end

  local health_info
  health_info, err = balancer.get_upstream_health(upstream_pk.id)
  if err then
    ngx.log(ngx.ERR, "failed getting upstream health: ", err)
  end

  for _, target in ipairs(active_targets) do
    -- In case of DNS errors when registering a target,
    -- that error happens inside lua-resty-dns-client
    -- and the end-result is that it just doesn't launch the callback,
    -- which means kong.runloop.balancer and healthchecks don't get
    -- notified about the target at all. We extrapolate the DNS error
    -- out of the fact that the target is missing from the balancer.
    -- Note that lua-resty-dns-client does retry by itself,
    -- meaning that if DNS is down and it eventually resumes working, the
    -- library will issue the callback and the target will change state.
    target.health = health_info
                   and (health_info[target.target] or "DNS_ERROR")
                   or  "HEALTHCHECKS_OFF"
  end

  return active_targets
end


function _TARGETS:post_health(upstream, target, is_healthy)
  local addr = utils.normalize_ip(target.target)
  local ip, port = utils.format_host(addr.host), addr.port
  local _, err = balancer.post_health(upstream, ip, port, is_healthy)
  if err then
    return nil, err
  end

  local health = is_healthy and 1 or 0
  local packet = ("%s|%d|%d|%s|%s"):format(ip, port, health,
                                           upstream.id,
                                           upstream.name)
  local cluster_events = require("kong.singletons").cluster_events
  cluster_events:broadcast("balancer:post_health", packet)
end

return _TARGETS
