local crd_watcher = require "crd_watcher"
local http = require "resty.http"
local str = require "resty.string"
local aws_signature = require "aws_signature"
local json = require "cjson"

local _M = {}

-- 构建 OSS URL
local function build_oss_request_params(upstream_spec, bucket, object_key)
    local protocol = upstream_spec.useHTTPS and "https" or "http"
    local endpoint = upstream_spec.endpoint

    local host = ""
    local uri = ""
    
    -- 分离路径和查询参数
    local path, query = object_key:match("([^?]*)(.*)")
    
    if upstream_spec.pathStyle then
        host = endpoint
        uri = "/" .. bucket .. path .. query
    else
        host = bucket .. "." .. endpoint
        uri = "/" .. path .. query
    end
    
    -- 添加调试日志
    ngx.log(ngx.DEBUG, "[oss_proxy] build_oss_request_params: object_key=", object_key)
    ngx.log(ngx.DEBUG, "[oss_proxy] build_oss_request_params: path=", path)
    ngx.log(ngx.DEBUG, "[oss_proxy] build_oss_request_params: query=", query)
    ngx.log(ngx.DEBUG, "[oss_proxy] build_oss_request_params: final_uri=", uri)

    return protocol, host, uri
end

-- 发起 OSS 请求
local function oss_request(protocol, host, uri, headers, upstream_spec, bucket)
    local httpc = http.new()
    
    -- 设置超时
    local timeout = upstream_spec.timeout or {}
    httpc:set_timeout((timeout.connect or 10) * 1000)
    
    local creds = upstream_spec.credentials
    if creds.accessKeyId and creds.secretAccessKey then
        local signed_headers = aws_signature.aws_get_headers(host, uri, upstream_spec.region, creds.accessKeyId, creds.secretAccessKey)
        headers = headers or {}
        for name, value in pairs(signed_headers) do
            ngx.log(ngx.DEBUG, "[oss_proxy] signed_headers: ", name, " = ", value)
            headers[name] = value
        end
    end
    
    local res, err = httpc:request_uri(protocol .. "://" .. host .. uri, {
        method = "GET",
        headers = headers,
        ssl_verify = upstream_spec.useHTTPS == true  -- 只有明确设置为true时才验证SSL
    })
    
    -- 添加调试日志
    local full_url = protocol .. "://" .. host .. uri
    ngx.log(ngx.DEBUG, "[oss_proxy] oss_request: full_url=", full_url)
    ngx.log(ngx.DEBUG, "[oss_proxy] oss_request: host=", host)
    ngx.log(ngx.DEBUG, "[oss_proxy] oss_request: uri=", uri)
    
    return res, err
end

-- 处理静态文件请求
function _M.handle_request()
    local host = ngx.var.http_host or ngx.var.host
    local uri = ngx.var.request_uri
    
    -- 记录请求开始时间用于指标收集
    local start_time = ngx.now()
    
    -- 添加调试信息
    ngx.log(ngx.INFO, "处理请求: ", host, uri)
    
    -- 获取路由配置
    local config, err = crd_watcher.get_route_config(host)
    if err then
        ngx.log(ngx.ERR, "获取路由配置失败: ", err)
        ngx.status = 500
        ngx.header["Content-Type"] = "text/plain; charset=utf-8"
        ngx.say("内部服务器错误: " .. err)
        -- 无法获取配置时，无法记录路由指标，但可以记录全局错误指标
        return
    end
    
    if not config then
        ngx.log(ngx.INFO, "未找到路由配置: ", host)
        ngx.status = 404
        ngx.header["Content-Type"] = "text/plain; charset=utf-8"
        ngx.say("未找到匹配的路由: " .. host)
        -- 同样无法记录路由指标
        return
    end
    
    local route_spec = config.route.spec
    local upstream_spec = config.upstream.spec
    
    -- 初始化指标收集
    local metrics_ok, metrics = pcall(require, "metrics")
    local route_namespace, route_name, upstream_namespace, upstream_name
    
    if metrics_ok then
        route_namespace = config.route.metadata.namespace
        route_name = config.route.metadata.name
        upstream_namespace = config.upstream.metadata.namespace
        upstream_name = config.upstream.metadata.name
    else
        ngx.log(ngx.ERR, "Failed to load metrics module in oss_proxy: " .. (metrics or "unknown error"))
    end
    
    -- 处理根路径
    if uri == "/" then
        uri = "/" .. (route_spec.indexFile or "index.html")
    end
    
    -- 构建对象键
    local object_key = (route_spec.prefix or "") .. string.sub(uri, 2) -- 去掉开头的 /
    
    -- 构建 OSS URL
    local protocol, oss_host, oss_uri = build_oss_request_params(upstream_spec, route_spec.bucket, object_key)
    
    -- 发起请求 - 使用与AWS签名相同的URI格式
    local res, request_err = oss_request(protocol, oss_host, uri, {}, upstream_spec, route_spec.bucket)
    
    if not res then
        ngx.log(ngx.ERR, "OSS 请求失败: ", request_err)
        ngx.status = 500
        ngx.say("内部服务器错误")
        
        -- 记录OSS请求失败的指标
        if metrics_ok and metrics and route_namespace and route_name then
            metrics.record_request_end("route", route_namespace, route_name, 500, start_time)
        end
        if metrics_ok and metrics and upstream_namespace and upstream_name then
            metrics.record_request_end("upstream", upstream_namespace, upstream_name, 500, start_time)
        end
        return
    end
    
    -- 处理 404 情况
    if res.status == 404 then
        if route_spec.spaApp then
            -- SPA 模式：返回 index 文件
            local index_key = (route_spec.prefix or "") .. (route_spec.indexFile or "index.html")
            local protocol, oss_host, oss_uri = build_oss_request_params(upstream_spec, route_spec.bucket, index_key)
            local index_res, index_err = oss_request(protocol, oss_host, "/" .. index_key, {}, upstream_spec, route_spec.bucket)
            
            if index_res and index_res.status == 200 then
                -- 设置正确的 Content-Type
                ngx.header["Content-Type"] = "text/html; charset=utf-8"
                
                -- 设置缓存头
                local cache_config = route_spec.cache or {}
                if cache_config.enabled ~= false then
                    local html_max_age = cache_config.htmlMaxAge or 300
                    ngx.header["Cache-Control"] = "public, max-age=" .. html_max_age
                end
                
                ngx.status = 200
                ngx.say(index_res.body)
                
                -- 记录SPA重定向的指标（状态码200，因为成功返回了index文件）
                if metrics_ok and metrics and route_namespace and route_name then
                    metrics.record_request_end("route", route_namespace, route_name, 200, start_time)
                end
                if metrics_ok and metrics and upstream_namespace and upstream_name then
                    metrics.record_request_end("upstream", upstream_namespace, upstream_name, 200, start_time)
                end
                return
            end
        else
            -- 检查是否有自定义 404 页面
            if route_spec.errorPages and route_spec.errorPages["404"] then
                local error_key = (route_spec.prefix or "") .. route_spec.errorPages["404"]
                local protocol, oss_host, oss_uri = build_oss_request_params(upstream_spec, route_spec.bucket, error_key)
                local error_res, error_err = oss_request(protocol, oss_host, "/" .. error_key, {}, upstream_spec, route_spec.bucket)
                
                if error_res and error_res.status == 200 then
                    ngx.header["Content-Type"] = "text/html; charset=utf-8"
                    ngx.status = 404
                    ngx.say(error_res.body)
                    
                    -- 记录自定义404页面的指标
                    if metrics_ok and metrics and route_namespace and route_name then
                        metrics.record_request_end("route", route_namespace, route_name, 404, start_time)
                    end
                    if metrics_ok and metrics and upstream_namespace and upstream_name then
                        metrics.record_request_end("upstream", upstream_namespace, upstream_name, 404, start_time)
                    end
                    return
                end
            end
        end
        
        ngx.status = 404
        ngx.say("页面未找到")
        
        -- 记录最终404的指标
        if metrics_ok and metrics and route_namespace and route_name then
            metrics.record_request_end("route", route_namespace, route_name, 404, start_time)
        end
        if metrics_ok and metrics and upstream_namespace and upstream_name then
            metrics.record_request_end("upstream", upstream_namespace, upstream_name, 404, start_time)
        end
        return
    end
    
    -- 处理其他错误状态码
    if res.status ~= 200 then
        ngx.status = res.status
        ngx.say("请求失败: " .. res.status)
        
        -- 记录其他错误状态码的指标
        if metrics_ok and metrics and route_namespace and route_name then
            metrics.record_request_end("route", route_namespace, route_name, res.status, start_time)
        end
        if metrics_ok and metrics and upstream_namespace and upstream_name then
            metrics.record_request_end("upstream", upstream_namespace, upstream_name, res.status, start_time)
        end
        return
    end
    
    -- 设置响应头
    if res.headers then
        for name, value in pairs(res.headers) do
            if name:lower() ~= "connection" and name:lower() ~= "transfer-encoding" then
                ngx.header[name] = value
            end
        end
    end
    
    -- 设置缓存头
    local cache_config = route_spec.cache or {}
    if cache_config.enabled ~= false then
        local max_age = cache_config.maxAge or 3600
        
        -- 根据文件类型设置不同的缓存时间
        local content_type = res.headers["content-type"] or ""
        if string.match(content_type, "text/html") then
            max_age = cache_config.htmlMaxAge or 300
        elseif string.match(uri, "%.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$") then
            max_age = cache_config.staticMaxAge or 86400
        end
        
        ngx.header["Cache-Control"] = "public, max-age=" .. max_age
    end
    
    -- 输出响应体
    ngx.status = res.status
    ngx.say(res.body)
    
    -- 记录指标（在响应完成后）
    if metrics_ok and metrics and route_namespace and route_name then
        metrics.record_request_end("route", route_namespace, route_name, res.status, start_time)
    end
    if metrics_ok and metrics and upstream_namespace and upstream_name then
        metrics.record_request_end("upstream", upstream_namespace, upstream_name, res.status, start_time)
    end
end

return _M