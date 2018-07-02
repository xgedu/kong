local endpoints   = require "kong.api.endpoints"
local responses = require "kong.tools.responses"
local balancer = require "kong.runloop.balancer"
local cluster_events = require("kong.singletons").cluster_events
local utils = require "kong.tools.utils"
local public = require "kong.tools.public"


local function select_upstream(upstream_id)
  local id = ngx.unescape_uri(upstream_id)
  if utils.is_valid_uuid(id) then
    return kong.db.upstreams.select({ id = id })
  end
  return kong.db.upstreams.select_by_name(upstream_id)
end


local function select_target(target_id)
  local id = ngx.unescape_uri(target_id)
  if utils.is_valid_uuid(id) then
    return kong.db.targets.select({ id = id })
  end
  return kong.db.targets.select_by_target(target_id)
end


local function post_health(self, is_healthy)
  local upstream, _, err_t = select_upstream(self.params.upstreams)
  if err_t then
    return endpoints.handle_error(err_t)
  end
  local target, _, err_t = select_target(self.params.targets)
  if err_t then
    return endpoints.handle_error(err_t)
  end

  local addr = utils.normalize_ip(target.target)
  local ip, port = utils.format_host(addr.host), addr.port
  local _, err = balancer.post_health(upstream, ip, port, is_healthy)
  if err then
    return endpoints.handle_error(err)
  end

  local health = is_healthy and 1 or 0
  local packet = ("%s|%d|%d|%s|%s"):format(ip, port, health,
                                           upstream.id,
                                           upstream.name)
  cluster_events:broadcast("balancer:post_health", packet)

  return responses.send_HTTP_NO_CONTENT()
end


return {
  ["/upstreams/:upstreams/health/"] = {
    GET = function(self, dao_factory)
      local upstream, _, err_t = select_upstream(self.params.upstreams)
      if err_t then
        return endpoints.handle_error(err_t)
      end

      local targets_with_health = kong.targets:for_upstream_with_health({ id = upstream.id })
      local node_id, err = public.get_node_id()
      if err then
        ngx.log(ngx.ERR, "failed getting node id: ", err)
      end

      return kong.response.exit(200, {
        data    = targets_with_health,
        node_id = node_id,
      })
    end
  },

  ["/upstreams/:upstreams/targets/all"] = {
    GET = function(self, dao_factory)
      local upstream, _, err_t = select_upstream(self.params.upstreams)
      if err_t then
        return endpoints.handle_error(err_t)
      end
      local targets = kong.db.targets:for_upstream({ id = upstream.id }, true)
      return kong.response.exit(200, {
        data  = targets,
      })
    end
  },

  ["/upstreams/:upstreams/targets/:targets/healthy"] = {
    POST = function(self)
      return post_health(self, true)
    end,
  },

  ["/upstreams/:upstreams/targets/:targets/unhealthy"] = {
    POST = function(self)
      return post_health(self, false)
    end,
  },
}
