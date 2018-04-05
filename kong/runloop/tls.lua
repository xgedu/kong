local http_tls = require "http.tls"
local openssl_pkey = require "openssl.pkey"
local x509 = require "openssl.x509"
local x509_store = require "openssl.x509.store"

local function get_ssl_ctx_for_service(service)
  local ssl_ctx = http_tls.new_client_context()

  if service.ca_cert then
    local ca_cert = x509.new(service.ca_cert)
    local store = x509_store.new()
    store:add(ca_cert)
    ssl_ctx:setStore(store)
  end

  if service.client_cert and service.client_key then
    local cert = x509.new(service.client_cert)
    ssl_ctx:setCertificate(cert)
    local key = openssl_pkey.new(service.client_key)
    ssl_ctx:setPrivateKey(key)
  end

  return ssl_ctx
end

return {
  get_ssl_ctx_for_service = get_ssl_ctx_for_service;
}
