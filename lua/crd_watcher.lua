local json = require "cjson"
local http = require "resty.http"
local lrucache = require "resty.lrucache"

local _M = {}

-- 全局缓存表（所有worker共享）
local crd_cache = {
    routes = {},   -- host -> route
    upstreams = {}, -- name/namespace -> upstream
    secrets = {},   -- name/namespace -> secret
    version = 0,    -- 资源版本号
    last_sync = 0,  -- 上次同步时间
    ready = false,  -- 新增，表示缓存是否已同步
}

local K8S_API_SERVER = os.getenv("KUBERNETES_SERVICE_HOST") or "kubernetes.default.svc.cluster.local"
local K8S_API_PORT = os.getenv("KUBERNETES_SERVICE_PORT") or "443"
local K8S_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
local K8S_CA_CERT_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

local function get_k8s_token()
    local file = io.open(K8S_TOKEN_PATH, "r")
    if not file then
        ngx.log(ngx.ERR, "无法读取 Kubernetes token")
        return nil
    end
    local token = file:read("*all")
    file:close()
    return token:gsub("%s+", "")
end

local function build_k8s_url(resource, namespace, watch, resourceVersion)
    local base_url = "https://" .. K8S_API_SERVER .. ":" .. K8S_API_PORT
    local url
    if namespace then
        url = base_url .. "/apis/ossfe.imvictor.tech/v1/namespaces/" .. namespace .. "/" .. resource
    else
        url = base_url .. "/apis/ossfe.imvictor.tech/v1/" .. resource
    end
    if watch then
        url = url .. "?watch=true"
        if resourceVersion then
            url = url .. "&resourceVersion=" .. resourceVersion
        end
    end
    return url
end

local function k8s_request(url, method)
    local httpc = http.new()
    httpc:set_timeout(5000)
    local token = get_k8s_token()
    if not token then
        return nil, "无法获取 Kubernetes token"
    end
    local ca_file = io.open(K8S_CA_CERT_PATH, "r")
    local use_ca = false
    if ca_file then ca_file:close(); use_ca = true end
    local res, err = httpc:request_uri(url, {
        method = method or "GET",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"] = "application/json"
        },
        ssl_verify = use_ca,
        ssl_trusted_certificate = use_ca and K8S_CA_CERT_PATH or nil
    })
    if not res then return nil, err end
    if res.status ~= 200 then return nil, "API请求失败: "..res.status end
    local ok, data = pcall(json.decode, res.body)
    if not ok then return nil, "JSON解析失败" end
    return data, nil
end

-- 拉取全量CRD并填充缓存
local function sync_all()
    ngx.log(ngx.INFO, "[crd_watcher] 全量同步CRD...")
    -- 1. routes
    local routes_data, err = k8s_request(build_k8s_url("ossproxyroutes"))
    if not routes_data then ngx.log(ngx.ERR, "[crd_watcher] 拉取routes失败: ", err); return end
    local new_routes = {}
    for _, route in ipairs(routes_data.items or {}) do
        if route.spec and route.spec.hosts then
            for _, host in ipairs(route.spec.hosts) do
                new_routes[host] = route
            end
        end
    end
    crd_cache.routes = new_routes
    -- 2. upstreams
    local upstreams_data, err = k8s_request(build_k8s_url("ossproxyupstreams"))
    if not upstreams_data then ngx.log(ngx.ERR, "[crd_watcher] 拉取upstreams失败: ", err); return end
    local new_ups = {}
    for _, up in ipairs(upstreams_data.items or {}) do
        local key = (up.metadata.namespace or "default") .. "/" .. up.metadata.name
        new_ups[key] = up
    end
    crd_cache.upstreams = new_ups
    -- 3. secrets（只缓存引用到的）
    -- 不预拉取，按需拉取
    crd_cache.version = (routes_data.metadata and routes_data.metadata.resourceVersion) or 0
    crd_cache.last_sync = ngx.now()
    crd_cache.ready = true  -- 同步成功，标记为ready
    ngx.log(ngx.INFO, "[crd_watcher] 全量同步完成 routes=", tostring(#(routes_data.items or {})), " upstreams=", tostring(#(upstreams_data.items or {})))
end

-- watch协程
local function watch_crd(premature)
    if premature then return end
    local httpc = require("resty.http").new()
    httpc:set_timeout(600000)  -- 10分钟
    local token = get_k8s_token()
    if not token then ngx.log(ngx.ERR, "[crd_watcher] 无法获取token"); return end
    local url = build_k8s_url("ossproxyroutes", nil, true, crd_cache.version)
    ngx.log(ngx.WARN, "[crd_watcher] 启动watch: ", url)
    local res, err = httpc:request_uri(url, {
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"] = "application/json"
        },
        ssl_verify = false,  -- 如需验证可改为 true 并加 ca
        keepalive = false,
    })
    if not res then
        ngx.log(ngx.ERR, "[crd_watcher] request失败: ", err)
        ngx.timer.at(1, watch_crd)
        return
    end
    if res.status ~= 200 then
        ngx.log(ngx.ERR, "[crd_watcher] watch返回非200: ", res.status, " body: ", res.body)
        ngx.timer.at(1, watch_crd)
        return
    end

    -- 按行处理事件
    local buffer = ""
    for line in res.body:gmatch("([^\n]*)\n?") do
        if line and #line > 0 then
            ngx.log(ngx.DEBUG, "[crd_watcher] event: ", line)
            local ok, event = pcall(json.decode, line)
            if ok and event and event.object then
                local obj = event.object
                if event.type == "ADDED" or event.type == "MODIFIED" then
                    if obj.spec and obj.spec.hosts then
                        for _, host in ipairs(obj.spec.hosts) do
                            crd_cache.routes[host] = obj
                        end
                    end
                elseif event.type == "DELETED" then
                    if obj.spec and obj.spec.hosts then
                        for _, host in ipairs(obj.spec.hosts) do
                            crd_cache.routes[host] = nil
                        end
                    end
                end
                crd_cache.version = obj.metadata and obj.metadata.resourceVersion or crd_cache.version
            end
        end
    end

    ngx.log(ngx.WARN, "[crd_watcher] watch结束，准备重连...")
    ngx.timer.at(1, watch_crd)
end

-- 定时全量同步兜底
local function periodic_sync(premature)
    if premature then return end
    sync_all()
    ngx.timer.at(300, periodic_sync) -- 5分钟
end

-- 提供init方法供init_by_lua_block调用
function _M.init()
    -- 只允许worker 0做同步和watch
    if ngx.worker and ngx.worker.id and ngx.worker.id() == 0 then
        ngx.timer.at(0, sync_all)
        ngx.timer.at(2, watch_crd)
        ngx.timer.at(300, periodic_sync)
    else
        ngx.log(ngx.INFO, "crd_watcher.init()：非worker 0，不做同步和watch")
    end
end

-- 获取本地缓存的route
function _M.find_route_by_host(host)
    local route = crd_cache.routes[host]
    if not route then
        return nil, nil
    end
    return route, nil
end

-- 获取本地缓存的upstream
function _M.get_upstream(name, namespace)
    local key = (namespace or "default") .. "/" .. name
    local up = crd_cache.upstreams[key]
    if not up then
        return nil, "未找到upstream"
    end
    -- 如果有secretRef，按需拉取并解码
    if up.spec and up.spec.credentials and up.spec.credentials.secretRef then
        local secret_ref = up.spec.credentials.secretRef
        local secret, secret_err = _M.get_secret(secret_ref.name, secret_ref.namespace or namespace)
        if secret_err then
            ngx.log(ngx.WARN, "获取Secret失败: ", secret_err)
        else
            if secret.data then
                local access_key_id = ngx.decode_base64(secret.data[secret_ref.accessKeyIdKey] or "")
                local secret_access_key = ngx.decode_base64(secret.data[secret_ref.secretAccessKeyKey] or "")
                up.spec.credentials.accessKeyId = access_key_id
                up.spec.credentials.secretAccessKey = secret_access_key
            end
        end
    end
    return up, nil
end

-- 按需拉取secret并缓存
function _M.get_secret(name, namespace)
    local key = (namespace or "default") .. "/" .. name
    if crd_cache.secrets[key] then return crd_cache.secrets[key], nil end
    local url = "https://" .. K8S_API_SERVER .. ":" .. K8S_API_PORT .. "/api/v1/namespaces/" .. (namespace or "default") .. "/secrets/" .. name
    local data, err = k8s_request(url)
    if err then return nil, err end
    crd_cache.secrets[key] = data
    return data, nil
end

-- 获取完整的路由配置（包含 upstream）
function _M.get_route_config(host)
    local route, err = _M.find_route_by_host(host)
    if err then return nil, err end
    if not route then return nil, nil end
    local upstream_ref = route.spec.upstreamRef
    local upstream, upstream_err = _M.get_upstream(upstream_ref.name, upstream_ref.namespace or route.metadata.namespace)
    if upstream_err then return nil, "获取 upstream 失败: " .. upstream_err end
    return {
        route = route,
        upstream = upstream
    }, nil
end

function _M.is_ready()
    return crd_cache.ready
end

return _M