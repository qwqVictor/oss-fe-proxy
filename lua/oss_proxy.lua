local crd_watcher = require "crd_watcher"
local http = require "resty.http"
local sha1 = require "resty.sha1"
local str = require "resty.string"

local _M = {}

-- 生成 AWS 签名 v4
local function aws_sign_v4(method, uri, headers, body, access_key, secret_key, region, service)
    local t = ngx.time()
    local date = os.date("!%Y%m%d", t)
    local datetime = os.date("!%Y%m%dT%H%M%SZ", t)
    
    -- 添加必需的头部
    headers["host"] = headers["host"] or ngx.var.host
    headers["x-amz-date"] = datetime
    headers["x-amz-content-sha256"] = "UNSIGNED-PAYLOAD"
    
    -- 创建标准请求
    local header_names = {}
    local signed_headers = {}
    for name, value in pairs(headers) do
        local lower_name = string.lower(name)
        table.insert(header_names, lower_name)
        signed_headers[lower_name] = value
    end
    table.sort(header_names)
    
    local canonical_headers = ""
    local signed_headers_str = ""
    for i, name in ipairs(header_names) do
        canonical_headers = canonical_headers .. name .. ":" .. signed_headers[name] .. "\n"
        if i > 1 then
            signed_headers_str = signed_headers_str .. ";"
        end
        signed_headers_str = signed_headers_str .. name
    end
    
    local canonical_request = method .. "\n" ..
                            uri .. "\n" ..
                            "" .. "\n" .. -- query string
                            canonical_headers .. "\n" ..
                            signed_headers_str .. "\n" ..
                            "UNSIGNED-PAYLOAD"
    
    -- 创建待签名字符串
    local algorithm = "AWS4-HMAC-SHA256"
    local credential_scope = date .. "/" .. region .. "/" .. service .. "/aws4_request"
    local string_to_sign = algorithm .. "\n" ..
                          datetime .. "\n" ..
                          credential_scope .. "\n" ..
                          sha1:new():update(canonical_request):final()
    
    -- 计算签名
    local function hmac_sha256(key, data)
        return ngx.hmac_sha256(key, data)
    end
    
    local signing_key = hmac_sha256(hmac_sha256(hmac_sha256(hmac_sha256("AWS4" .. secret_key, date), region), service), "aws4_request")
    local signature = str.to_hex(hmac_sha256(signing_key, string_to_sign))
    
    -- 生成 Authorization 头部
    local authorization = algorithm .. " " ..
                         "Credential=" .. access_key .. "/" .. credential_scope .. ", " ..
                         "SignedHeaders=" .. signed_headers_str .. ", " ..
                         "Signature=" .. signature
    
    return authorization
end

-- 构建 OSS URL
local function build_oss_url(upstream_spec, bucket, object_key)
    local protocol = upstream_spec.useHTTPS and "https" or "http"
    local endpoint = upstream_spec.endpoint
    
    if upstream_spec.pathStyle then
        return protocol .. "://" .. endpoint .. "/" .. bucket .. "/" .. object_key
    else
        return protocol .. "://" .. bucket .. "." .. endpoint .. "/" .. object_key
    end
end

-- 发起 OSS 请求
local function oss_request(url, method, headers, upstream_spec, bucket)
    local httpc = http.new()
    
    -- 设置超时
    local timeout = upstream_spec.timeout or {}
    httpc:set_timeout((timeout.connect or 10) * 1000)
    
    -- 如果是 AWS 类型，需要签名
    if upstream_spec.provider == "aws" then
        local creds = upstream_spec.credentials
        if creds.accessKeyId and creds.secretAccessKey then
            local auth = aws_sign_v4(method or "GET", 
                                   ngx.var.uri, 
                                   headers or {}, 
                                   "", 
                                   creds.accessKeyId, 
                                   creds.secretAccessKey, 
                                   upstream_spec.region, 
                                   "s3")
            headers = headers or {}
            headers["Authorization"] = auth
        end
    end
    
    local res, err = httpc:request_uri(url, {
        method = method or "GET",
        headers = headers,
        ssl_verify = upstream_spec.useHTTPS == true  -- 只有明确设置为true时才验证SSL
    })
    
    return res, err
end

-- 处理静态文件请求
function _M.handle_request()
    local host = ngx.var.http_host or ngx.var.host
    local uri = ngx.var.uri
    
    -- 添加调试信息
    ngx.log(ngx.INFO, "处理请求: ", host, uri)
    
    -- 获取路由配置
    local config, err = crd_watcher.get_route_config(host)
    if err then
        ngx.log(ngx.ERR, "获取路由配置失败: ", err)
        ngx.status = 500
        ngx.header["Content-Type"] = "text/plain; charset=utf-8"
        ngx.say("内部服务器错误: " .. err)
        return
    end
    
    if not config then
        ngx.log(ngx.INFO, "未找到路由配置: ", host)
        ngx.status = 404
        ngx.header["Content-Type"] = "text/plain; charset=utf-8"
        ngx.say("未找到匹配的路由: " .. host)
        return
    end
    
    local route_spec = config.route.spec
    local upstream_spec = config.upstream.spec
    
    -- 处理根路径
    if uri == "/" then
        uri = "/" .. (route_spec.indexFile or "index.html")
    end
    
    -- 构建对象键
    local object_key = (route_spec.prefix or "") .. string.sub(uri, 2) -- 去掉开头的 /
    
    -- 构建 OSS URL
    local oss_url = build_oss_url(upstream_spec, route_spec.bucket, object_key)
    
    -- 发起请求
    local res, request_err = oss_request(oss_url, "GET", {}, upstream_spec, route_spec.bucket)
    
    if not res then
        ngx.log(ngx.ERR, "OSS 请求失败: ", request_err)
        ngx.status = 500
        ngx.say("内部服务器错误")
        return
    end
    
    -- 处理 404 情况
    if res.status == 404 then
        if route_spec.spaApp then
            -- SPA 模式：返回 index 文件
            local index_key = (route_spec.prefix or "") .. (route_spec.indexFile or "index.html")
            local index_url = build_oss_url(upstream_spec, route_spec.bucket, index_key)
            local index_res, index_err = oss_request(index_url, "GET", {}, upstream_spec, route_spec.bucket)
            
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
                return
            end
        else
            -- 检查是否有自定义 404 页面
            if route_spec.errorPages and route_spec.errorPages["404"] then
                local error_key = (route_spec.prefix or "") .. route_spec.errorPages["404"]
                local error_url = build_oss_url(upstream_spec, route_spec.bucket, error_key)
                local error_res, error_err = oss_request(error_url, "GET", {}, upstream_spec, route_spec.bucket)
                
                if error_res and error_res.status == 200 then
                    ngx.header["Content-Type"] = "text/html; charset=utf-8"
                    ngx.status = 404
                    ngx.say(error_res.body)
                    return
                end
            end
        end
        
        ngx.status = 404
        ngx.say("页面未找到")
        return
    end
    
    -- 处理其他错误状态码
    if res.status ~= 200 then
        ngx.status = res.status
        ngx.say("请求失败: " .. res.status)
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
end

return _M