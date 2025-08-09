local json = require "cjson"

local _M = {}

-- 全局缓存表（所有worker共享）
local crd_cache = {
    routes = {},     -- host -> route
    upstreams = {},  -- name/namespace -> upstream
    secrets = {},    -- name/namespace -> secret
    version = 0,     -- 资源版本号
    last_sync = 0,   -- 上次同步时间
    ready = false,   -- 表示缓存是否已同步
    synced_once = false, -- 是否已经完成首次全量同步
}

-- HTTP API 端点处理函数

-- 更新路由缓存
function _M.update_route(route_data)
    if not route_data or not route_data.spec or not route_data.spec.hosts then
        return false, "invalid route data"
    end
    
    for _, host in ipairs(route_data.spec.hosts) do
        crd_cache.routes[host] = route_data
    end
    
    crd_cache.version = route_data.metadata and route_data.metadata.resourceVersion or crd_cache.version
    crd_cache.last_sync = ngx.now()
    
    -- 首次同步数据后置为 ready
    if not crd_cache.synced_once then
        crd_cache.synced_once = true
        crd_cache.ready = true
        ngx.log(ngx.INFO, "[crd_watcher] 首次同步完成，设置为 ready")
    end
    
    ngx.log(ngx.INFO, "[crd_watcher] 更新路由: ", table.concat(route_data.spec.hosts, ", "))
    return true, nil
end

-- 删除路由缓存
function _M.delete_route(route_data)
    if not route_data or not route_data.spec or not route_data.spec.hosts then
        return false, "invalid route data"
    end
    
    for _, host in ipairs(route_data.spec.hosts) do
        crd_cache.routes[host] = nil
    end
    
    crd_cache.version = route_data.metadata and route_data.metadata.resourceVersion or crd_cache.version
    crd_cache.last_sync = ngx.now()
    
    ngx.log(ngx.INFO, "[crd_watcher] 删除路由: ", table.concat(route_data.spec.hosts, ", "))
    return true, nil
end

-- 更新 upstream 缓存
function _M.update_upstream(upstream_data)
    if not upstream_data or not upstream_data.metadata then
        return false, "invalid upstream data"
    end
    
    local key = (upstream_data.metadata.namespace or "default") .. "/" .. upstream_data.metadata.name
    crd_cache.upstreams[key] = upstream_data
    
    crd_cache.last_sync = ngx.now()
    
    -- 首次同步数据后置为 ready
    if not crd_cache.synced_once then
        crd_cache.synced_once = true
        crd_cache.ready = true
        ngx.log(ngx.INFO, "[crd_watcher] 首次同步完成，设置为 ready")
    end
    
    ngx.log(ngx.INFO, "[crd_watcher] 更新upstream: ", key)
    return true, nil
end

-- 删除 upstream 缓存
function _M.delete_upstream(upstream_data)
    if not upstream_data or not upstream_data.metadata then
        return false, "invalid upstream data"
    end
    
    local key = (upstream_data.metadata.namespace or "default") .. "/" .. upstream_data.metadata.name
    crd_cache.upstreams[key] = nil
    
    crd_cache.last_sync = ngx.now()
    
    ngx.log(ngx.INFO, "[crd_watcher] 删除upstream: ", key)
    return true, nil
end

-- 更新 secret 缓存
function _M.update_secret(secret_data)
    if not secret_data or not secret_data.metadata then
        return false, "invalid secret data"
    end
    
    local key = (secret_data.metadata.namespace or "default") .. "/" .. secret_data.metadata.name
    crd_cache.secrets[key] = secret_data
    
    crd_cache.last_sync = ngx.now()
    
    ngx.log(ngx.INFO, "[crd_watcher] 更新secret: ", key)
    return true, nil
end

-- 删除 secret 缓存
function _M.delete_secret(secret_data)
    if not secret_data or not secret_data.metadata then
        return false, "invalid secret data"
    end
    
    local key = (secret_data.metadata.namespace or "default") .. "/" .. secret_data.metadata.name
    crd_cache.secrets[key] = nil
    
    crd_cache.last_sync = ngx.now()
    
    ngx.log(ngx.INFO, "[crd_watcher] 删除secret: ", key)
    return true, nil
end

-- 获取缓存状态
function _M.get_cache_status()
    local route_count = 0
    for _ in pairs(crd_cache.routes) do
        route_count = route_count + 1
    end
    
    local upstream_count = 0
    for _ in pairs(crd_cache.upstreams) do
        upstream_count = upstream_count + 1
    end
    
    local secret_count = 0
    for _ in pairs(crd_cache.secrets) do
        secret_count = secret_count + 1
    end
    
    return {
        ready = crd_cache.ready,
        synced_once = crd_cache.synced_once,
        version = crd_cache.version,
        last_sync = crd_cache.last_sync,
        route_count = route_count,
        upstream_count = upstream_count,
        secret_count = secret_count
    }
end

-- 提供init方法供init_by_lua_block调用
function _M.init()
    -- 不再主动同步 K8S，只等待 Go watcher 推送数据
    ngx.log(ngx.INFO, "[crd_watcher] 初始化完成，等待 Go watcher 推送数据...")
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

-- 获取缓存的 secret
function _M.get_secret(name, namespace)
    local key = (namespace or "default") .. "/" .. name
    if crd_cache.secrets[key] then 
        return crd_cache.secrets[key], nil 
    end
    -- Secret 未缓存，应该由 Go watcher 提供
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
    return crd_cache.ready
end

-- 获取所有路由数据（用于指标收集）
function _M.get_all_routes()
    return crd_cache.routes
end

-- 获取所有上游数据（用于指标收集）
function _M.get_all_upstreams()
    return crd_cache.upstreams
end

return _M