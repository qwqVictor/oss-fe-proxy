local json = require "cjson"

local _M = {}

-- 使用共享字典来存储状态，确保多 worker 进程间同步
local crd_cache = ngx.shared.crd_cache
if not crd_cache then
    error("crd_cache shared dict not found in nginx.conf")
end

-- 初始化共享字典中的状态（如果不存在）
local function init_shared_state()
    if not crd_cache:get("ready") then
        crd_cache:set("ready", false)
        crd_cache:set("synced_once", false)
        crd_cache:set("version", 0)
        crd_cache:set("last_sync", 0)
        ngx.log(ngx.INFO, "[crd_watcher] 初始化共享状态")
    end
end

-- 检查是否应该设置为 ready 状态
local function update_ready_status()
    -- 从共享字典读取当前状态
    local ready = crd_cache:get("ready")
    local synced_once = crd_cache:get("synced_once")
    
    -- 检查是否有路由数据
    local has_routes = false
    local routes_json = crd_cache:get("routes")
    if routes_json then
        local routes = json.decode(routes_json)
        if routes and type(routes) == "table" then
            for _ in pairs(routes) do
                has_routes = true
                break
            end
        end
    end
    
    -- 一旦首次同步完成，ready 就保持为 true，不再变为 false
    if not synced_once and has_routes then
        crd_cache:set("synced_once", true)
        crd_cache:set("ready", true)
        ngx.log(ngx.INFO, "[crd_watcher] 首次同步完成，设置为 ready")
    elseif synced_once and not has_routes then
        -- 记录警告：首次同步后路由被清空，但保持 ready 状态
        ngx.log(ngx.WARN, "[crd_watcher] 警告：首次同步后路由被清空，但保持 ready 状态以避免 503 错误")
    end
end

-- 更新路由缓存
function _M.update_route(route_data)
    if not route_data or not route_data.spec or not route_data.spec.hosts then
        return false, "invalid route data"
    end
    
    -- 读取现有路由
    local routes = {}
    local routes_json = crd_cache:get("routes")
    if routes_json then
        routes = json.decode(routes_json) or {}
    end
    
    -- 更新路由
    for _, host in ipairs(route_data.spec.hosts) do
        routes[host] = route_data
    end
    
    -- 写回共享字典
    crd_cache:set("routes", json.encode(routes))
    crd_cache:set("version", route_data.metadata and route_data.metadata.resourceVersion or crd_cache:get("version"))
    crd_cache:set("last_sync", ngx.now())
    
    -- 更新 ready 状态
    update_ready_status()
    
    ngx.log(ngx.INFO, "[crd_watcher] 更新路由: ", table.concat(route_data.spec.hosts, ", "))
    return true, nil
end

-- 删除路由缓存
function _M.delete_route(route_data)
    if not route_data or not route_data.spec or not route_data.spec.hosts then
        return false, "invalid route data"
    end
    
    -- 读取现有路由
    local routes = {}
    local routes_json = crd_cache:get("routes")
    if routes_json then
        routes = json.decode(routes_json) or {}
    end
    
    -- 删除路由
    for _, host in ipairs(route_data.spec.hosts) do
        routes[host] = nil
    end
    
    -- 写回共享字典
    crd_cache:set("routes", json.encode(routes))
    crd_cache:set("version", route_data.metadata and route_data.metadata.resourceVersion or crd_cache:get("version"))
    crd_cache:set("last_sync", ngx.now())
    
    -- 更新 ready 状态
    update_ready_status()
    
    ngx.log(ngx.INFO, "[crd_watcher] 删除路由: ", table.concat(route_data.spec.hosts, ", "))
    return true, nil
end

-- 更新 upstream 缓存
function _M.update_upstream(upstream_data)
    if not upstream_data or not upstream_data.metadata then
        return false, "invalid upstream data"
    end
    
    local key = (upstream_data.metadata.namespace or "default") .. "/" .. upstream_data.metadata.name
    
    -- 读取现有 upstreams
    local upstreams = {}
    local upstreams_json = crd_cache:get("upstreams")
    if upstreams_json then
        upstreams = json.decode(upstreams_json) or {}
    end
    
    -- 更新 upstream
    upstreams[key] = upstream_data
    
    -- 写回共享字典
    crd_cache:set("upstreams", json.encode(upstreams))
    crd_cache:set("last_sync", ngx.now())
    
    -- 更新 ready 状态（上游更新不影响 ready 状态，因为主要依赖路由）
    update_ready_status()
    
    ngx.log(ngx.INFO, "[crd_watcher] 更新upstream: ", key)
    return true, nil
end

-- 删除 upstream 缓存
function _M.delete_upstream(upstream_data)
    if not upstream_data or not upstream_data.metadata then
        return false, "invalid upstream data"
    end
    
    local key = (upstream_data.metadata.namespace or "default") .. "/" .. upstream_data.metadata.name
    
    -- 读取现有 upstreams
    local upstreams = {}
    local upstreams_json = crd_cache:get("upstreams")
    if upstreams_json then
        upstreams = json.decode(upstreams_json) or {}
    end
    
    -- 删除 upstream
    upstreams[key] = nil
    
    -- 写回共享字典
    crd_cache:set("upstreams", json.encode(upstreams))
    crd_cache:set("last_sync", ngx.now())
    
    -- 更新 ready 状态
    update_ready_status()
    
    ngx.log(ngx.INFO, "[crd_watcher] 删除upstream: ", key)
    return true, nil
end

-- 更新 secret 缓存
function _M.update_secret(secret_data)
    if not secret_data or not secret_data.metadata then
        return false, "invalid secret data"
    end
    
    local key = (secret_data.metadata.namespace or "default") .. "/" .. secret_data.metadata.name
    
    -- 读取现有 secrets
    local secrets = {}
    local secrets_json = crd_cache:get("secrets")
    if secrets_json then
        secrets = json.decode(secrets_json) or {}
    end
    
    -- 更新 secret
    secrets[key] = secret_data
    
    -- 写回共享字典
    crd_cache:set("secrets", json.encode(secrets))
    crd_cache:set("last_sync", ngx.now())
    
    ngx.log(ngx.INFO, "[crd_watcher] 更新secret: ", key)
    return true, nil
end

-- 删除 secret 缓存
function _M.delete_secret(secret_data)
    if not secret_data or not secret_data.metadata then
        return false, "invalid secret data"
    end
    
    local key = (secret_data.metadata.namespace or "default") .. "/" .. secret_data.metadata.name
    
    -- 读取现有 secrets
    local secrets = {}
    local secrets_json = crd_cache:get("secrets")
    if secrets_json then
        secrets = json.decode(secrets_json) or {}
    end
    
    -- 删除 secret
    secrets[key] = nil
    
    -- 写回共享字典
    crd_cache:set("secrets", json.encode(secrets))
    crd_cache:set("last_sync", ngx.now())
    
    ngx.log(ngx.INFO, "[crd_watcher] 删除secret: ", key)
    return true, nil
end

-- 获取缓存状态
function _M.get_cache_status()
    local route_count = 0
    local routes_json = crd_cache:get("routes")
    if routes_json then
        local routes = json.decode(routes_json)
        if routes and type(routes) == "table" then
            for _ in pairs(routes) do
                route_count = route_count + 1
            end
        end
    end
    
    local upstream_count = 0
    local upstreams_json = crd_cache:get("upstreams")
    if upstreams_json then
        local upstreams = json.decode(upstreams_json)
        if upstreams and type(upstreams) == "table" then
            for _ in pairs(upstreams) do
                upstream_count = upstream_count + 1
            end
        end
    end
    
    local secret_count = 0
    local secrets_json = crd_cache:get("secrets")
    if secrets_json then
        local secrets = json.decode(secrets_json)
        if secrets and type(secrets) == "table" then
            for _ in pairs(secrets) do
                secret_count = secret_count + 1
            end
        end
    end
    
    return {
        ready = crd_cache:get("ready"),
        synced_once = crd_cache:get("synced_once"),
        version = crd_cache:get("version"),
        last_sync = crd_cache:get("last_sync"),
        route_count = route_count,
        upstream_count = upstream_count,
        secret_count = secret_count
    }
end

-- 提供init方法供init_by_lua_block调用
function _M.init()
    -- 初始化共享状态
    init_shared_state()
    ngx.log(ngx.INFO, "[crd_watcher] 初始化完成，等待 Go watcher 推送数据...")
end

-- 获取本地缓存的route
function _M.find_route_by_host(host)
    local routes_json = crd_cache:get("routes")
    if not routes_json then
        return nil, nil
    end
    
    local routes = json.decode(routes_json)
    if not routes or type(routes) ~= "table" then
        return nil, nil
    end
    
    local route = routes[host]
    if not route then
        return nil, nil
    end
    return route, nil
end

-- 获取本地缓存的upstream
function _M.get_upstream(name, namespace)
    local key = (namespace or "default") .. "/" .. name
    
    local upstreams_json = crd_cache:get("upstreams")
    if not upstreams_json then
        return nil, "未找到upstream"
    end
    
    local upstreams = json.decode(upstreams_json)
    if not upstreams or type(upstreams) ~= "table" then
        return nil, "未找到upstream"
    end
    
    local up = upstreams[key]
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

-- 获取缓存的 secret
function _M.get_secret(name, namespace)
    local key = (namespace or "default") .. "/" .. name
    
    local secrets_json = crd_cache:get("secrets")
    if not secrets_json then
        return nil, "Secret not found in cache: " .. key
    end
    
    local secrets = json.decode(secrets_json)
    if not secrets or type(secrets) ~= "table" then
        return nil, "Secret not found in cache: " .. key
    end
    
    if secrets[key] then 
        return secrets[key], nil 
    end
    
    return nil, "Secret not found in cache: " .. key
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
    -- 从共享字典读取状态
    local ready = crd_cache:get("ready")
    local synced_once = crd_cache:get("synced_once")
    
    -- 检查路由数量
    local route_count = 0
    local routes_json = crd_cache:get("routes")
    if routes_json then
        local routes = json.decode(routes_json)
        if routes and type(routes) == "table" then
            for _ in pairs(routes) do
                route_count = route_count + 1
            end
        end
    end
    
    ngx.log(ngx.INFO, string.format("[crd_watcher] is_ready() 调用: ready=%s, synced_once=%s, route_count=%d", 
        tostring(ready), tostring(synced_once), route_count))
    
    return ready
end

-- 获取所有路由数据（用于指标收集）
function _M.get_all_routes()
    local routes_json = crd_cache:get("routes")
    if not routes_json then
        return {}
    end
    
    local routes = json.decode(routes_json)
    if not routes or type(routes) ~= "table" then
        return {}
    end
    
    return routes
end

-- 获取所有上游数据（用于指标收集）
function _M.get_all_upstreams()
    local upstreams_json = crd_cache:get("upstreams")
    if not upstreams_json then
        return {}
    end
    
    local upstreams = json.decode(upstreams_json)
    if not upstreams or type(upstreams) ~= "table" then
        return {}
    end
    
    return upstreams
end

return _M