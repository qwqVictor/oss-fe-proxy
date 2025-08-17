--[[
Copyright 2018 JobTeaser

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
--]]

local resty_hmac = require('resty.hmac')
local resty_sha256 = require('resty.sha256')
local str = require('resty.string')

local _M = { _VERSION = '0.1.2' }

local function get_credentials ()
  local access_key = os.getenv('AWS_ACCESS_KEY_ID')
  local secret_key = os.getenv('AWS_SECRET_ACCESS_KEY')

  return {
    access_key = access_key,
    secret_key = secret_key
  }
end

local function get_iso8601_basic(timestamp)
  return os.date('!%Y%m%dT%H%M%SZ', timestamp)
end

local function get_iso8601_basic_short(timestamp)
  return os.date('!%Y%m%d', timestamp)
end

local function get_derived_signing_key(keys, timestamp, region, service)
  local h_date = resty_hmac:new('AWS4' .. keys['secret_key'], resty_hmac.ALGOS.SHA256)
  h_date:update(get_iso8601_basic_short(timestamp))
  local k_date = h_date:final()

  local h_region = resty_hmac:new(k_date, resty_hmac.ALGOS.SHA256)
  h_region:update(region)
  local k_region = h_region:final()

  local h_service = resty_hmac:new(k_region, resty_hmac.ALGOS.SHA256)
  h_service:update(service)
  local k_service = h_service:final()

  local h = resty_hmac:new(k_service, resty_hmac.ALGOS.SHA256)
  h:update('aws4_request')
  return h:final()
end

local function get_cred_scope(timestamp, region, service)
  return get_iso8601_basic_short(timestamp)
    .. '/' .. region
    .. '/' .. service
    .. '/aws4_request'
end

local function get_signed_headers()
  return 'host;x-amz-content-sha256;x-amz-date'
end

local function get_sha256_digest(s)
  local h = resty_sha256:new()
  h:update(s or '')
  return str.to_hex(h:final())
end

-- 解析查询参数并按照AWS规范排序
local function parse_and_sort_query_params(uri)
  local path, query = uri:match("([^?]*)(.*)")
  if not query or query == "" then
    return path, ""
  end
  
  -- 去掉开头的 ?
  query = query:sub(2)
  
  -- 解析查询参数
  local params = {}
  for param in query:gmatch("[^&]+") do
    local key, value = param:match("([^=]*)=?(.*)")
    if key and key ~= "" then
      -- 如果值不存在，设置为空字符串
      value = value or ""
      -- 按照AWS规范，查询参数应该保持原始格式，不进行URL解码
      -- 但是需要确保key和value都是正确的格式
      params[key] = value
    end
  end
  
  -- 按字母顺序排序参数
  local sorted_keys = {}
  for key in pairs(params) do
    table.insert(sorted_keys, key)
  end
  table.sort(sorted_keys)
  
  -- 构建排序后的查询字符串
  local sorted_query = ""
  for i, key in ipairs(sorted_keys) do
    if i > 1 then
      sorted_query = sorted_query .. "&"
    end
    sorted_query = sorted_query .. key .. "=" .. params[key]
  end
  
  return path, sorted_query
end

local function get_hashed_canonical_request(timestamp, host, uri)
  local digest = get_sha256_digest("")
  
  -- 解析并排序查询参数
  local path, query = parse_and_sort_query_params(uri)
  
  -- 添加调试日志
  ngx.log(ngx.DEBUG, "[aws_signature] Original URI: ", uri)
  ngx.log(ngx.DEBUG, "[aws_signature] Parsed path: ", path)
  ngx.log(ngx.DEBUG, "[aws_signature] Parsed query: ", query)
  
  -- 构建规范请求，查询参数单独一行
  local canonical_request = "GET" .. '\n'
    .. path .. '\n'
    .. query .. '\n'
    .. 'host:' .. host .. '\n'
    .. 'x-amz-content-sha256:' .. digest .. '\n'
    .. 'x-amz-date:' .. get_iso8601_basic(timestamp) .. '\n'
    .. '\n'
    .. get_signed_headers() .. '\n'
    .. digest
  
  -- 添加调试日志
  ngx.log(ngx.DEBUG, "[aws_signature] Canonical request:\n", canonical_request)
  
  return get_sha256_digest(canonical_request)
end

local function get_string_to_sign(timestamp, region, service, host, uri)
  return 'AWS4-HMAC-SHA256\n'
    .. get_iso8601_basic(timestamp) .. '\n'
    .. get_cred_scope(timestamp, region, service) .. '\n'
    .. get_hashed_canonical_request(timestamp, host, uri)
end

local function get_signature(derived_signing_key, string_to_sign)
  local h = resty_hmac:new(derived_signing_key, resty_hmac.ALGOS.SHA256)
  h:update(string_to_sign)
  return h:final(nil, true)
end

local function get_authorization(keys, timestamp, region, service, host, uri)
  local derived_signing_key = get_derived_signing_key(keys, timestamp, region, service)
  local string_to_sign = get_string_to_sign(timestamp, region, service, host, uri)
  
  -- 添加调试日志
  ngx.log(ngx.DEBUG, "[aws_signature] get_authorization: timestamp=", timestamp)
  ngx.log(ngx.DEBUG, "[aws_signature] get_authorization: region=", region)
  ngx.log(ngx.DEBUG, "[aws_signature] get_authorization: service=", service)
  ngx.log(ngx.DEBUG, "[aws_signature] get_authorization: host=", host)
  ngx.log(ngx.DEBUG, "[aws_signature] get_authorization: uri=", uri)
  ngx.log(ngx.DEBUG, "[aws_signature] get_authorization: string_to_sign=\n", string_to_sign)
  
  local auth = 'AWS4-HMAC-SHA256 '
    .. 'Credential=' .. keys['access_key'] .. '/' .. get_cred_scope(timestamp, region, service)
    .. ', SignedHeaders=' .. get_signed_headers()
    .. ', Signature=' .. get_signature(derived_signing_key, string_to_sign)
  return auth
end

function _M.aws_get_headers(host, uri, region, access_key, secret_key)
  local creds = {
    access_key = access_key,
    secret_key = secret_key
  }
  local timestamp = ngx.time()
  local service = 's3'
  
  -- 添加调试日志
  ngx.log(ngx.DEBUG, "[aws_signature] aws_get_headers: input_host=", host)
  ngx.log(ngx.DEBUG, "[aws_signature] aws_get_headers: input_uri=", uri)
  ngx.log(ngx.DEBUG, "[aws_signature] aws_get_headers: region=", region)
  ngx.log(ngx.DEBUG, "[aws_signature] aws_get_headers: timestamp=", timestamp)
  ngx.log(ngx.DEBUG, "[aws_signature] aws_get_headers: iso8601_timestamp=", get_iso8601_basic(timestamp))
  
  local auth = get_authorization(creds, timestamp, region, service, host, uri)

  local signed_headers = {
    Authorization = auth,
    Host = host,
    ['x-amz-date'] = get_iso8601_basic(timestamp),
    ['x-amz-content-sha256'] = get_sha256_digest("")
  }
  
  -- 添加调试日志
  ngx.log(ngx.DEBUG, "[aws_signature] aws_get_headers: final_Authorization=", auth)
  ngx.log(ngx.DEBUG, "[aws_signature] aws_get_headers: final_Host=", host)
  
  return signed_headers
end

return _M