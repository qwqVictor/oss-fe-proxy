local crd_watcher = require "crd_watcher"
local status = crd_watcher.get_cache_status()

-- Nginx 连接指标
ngx.say("# HELP nginx_connections_active Active connections")
ngx.say("# TYPE nginx_connections_active gauge")
ngx.say("nginx_connections_active ", ngx.var.connections_active)

ngx.say("# HELP nginx_connections_reading Reading connections")
ngx.say("# TYPE nginx_connections_reading gauge")
ngx.say("nginx_connections_reading ", ngx.var.connections_reading)

ngx.say("# HELP nginx_connections_writing Writing connections")
ngx.say("# TYPE nginx_connections_writing gauge")
ngx.say("nginx_connections_writing ", ngx.var.connections_writing)

ngx.say("# HELP nginx_connections_waiting Waiting connections")
ngx.say("# TYPE nginx_connections_waiting gauge")
ngx.say("nginx_connections_waiting ", ngx.var.connections_waiting)

-- CRD 缓存指标
ngx.say("# HELP ossfe_proxy_ready Proxy ready status (1=ready, 0=not ready)")
ngx.say("# TYPE ossfe_proxy_ready gauge")
ngx.say("ossfe_proxy_ready ", status.ready and 1 or 0)

ngx.say("# HELP ossfe_proxy_synced_once Initial sync completed status (1=completed, 0=not completed)")
ngx.say("# TYPE ossfe_proxy_synced_once gauge")
ngx.say("ossfe_proxy_synced_once ", status.synced_once and 1 or 0)

ngx.say("# HELP ossfe_proxy_routes_total Total number of cached routes")
ngx.say("# TYPE ossfe_proxy_routes_total gauge")
ngx.say("ossfe_proxy_routes_total ", status.route_count)

ngx.say("# HELP ossfe_proxy_upstreams_total Total number of cached upstreams")
ngx.say("# TYPE ossfe_proxy_upstreams_total gauge")
ngx.say("ossfe_proxy_upstreams_total ", status.upstream_count)

ngx.say("# HELP ossfe_proxy_secrets_total Total number of cached secrets")
ngx.say("# TYPE ossfe_proxy_secrets_total gauge")
ngx.say("ossfe_proxy_secrets_total ", status.secret_count)

ngx.say("# HELP ossfe_proxy_last_sync_timestamp Last sync timestamp (unix time)")
ngx.say("# TYPE ossfe_proxy_last_sync_timestamp gauge")
ngx.say("ossfe_proxy_last_sync_timestamp ", status.last_sync)

ngx.say("# HELP ossfe_proxy_resource_version Current resource version")
ngx.say("# TYPE ossfe_proxy_resource_version gauge")
ngx.say("ossfe_proxy_resource_version ", status.version)

-- 添加详细的路由和上游指标
local ok, metrics = pcall(require, "metrics")
if not ok then
    ngx.log(ngx.ERR, "Failed to load metrics module: " .. (metrics or "unknown error"))
    ngx.say("# ERROR: metrics module failed to load: " .. (metrics or "unknown error"))
else
    -- 获取路由和上游数据
    local all_routes = crd_watcher.get_all_routes()
    local all_upstreams = crd_watcher.get_all_upstreams()
    
    -- 调试信息
    local route_count = 0
    local upstream_count = 0
    
    if all_routes then
        for _ in pairs(all_routes) do
            route_count = route_count + 1
        end
    end
    
    if all_upstreams then
        for _ in pairs(all_upstreams) do
            upstream_count = upstream_count + 1
        end
    end
    
    -- 路由指标 - 注意：all_routes 是 host -> route_data 的映射
    -- 我们需要去重，避免同一个路由重复输出指标
    local processed_routes = {}
    for host, route_data in pairs(all_routes or {}) do
        local namespace = route_data.metadata and route_data.metadata.namespace or "default"
        local name = route_data.metadata and route_data.metadata.name or "unknown"
        local route_key = namespace .. "/" .. name
        
        -- 避免重复处理同一个路由（一个路由可能有多个 host）
        if not processed_routes[route_key] then
            processed_routes[route_key] = true
            
            local route_metrics_ok, route_metrics = pcall(metrics.get_metrics, "route", namespace, name)
            
            if route_metrics_ok and route_metrics then
                local labels = string.format('route="%s",namespace="%s"', name, namespace)
                
                -- 请求总数
                ngx.say("# HELP ossfe_proxy_route_requests_total Total number of requests")
                ngx.say("# TYPE ossfe_proxy_route_requests_total counter")
                ngx.say("ossfe_proxy_route_requests_total{" .. labels .. "} " .. (route_metrics.cnt or 0))
                
                -- 吞吐量指标
                ngx.say("# HELP ossfe_proxy_route_throughput_rpm Requests per minute")
                ngx.say("# TYPE ossfe_proxy_route_throughput_rpm gauge")
                ngx.say("ossfe_proxy_route_throughput_rpm{" .. labels .. ",window=\"1m\"} " .. (route_metrics.m1 or 0))
                ngx.say("ossfe_proxy_route_throughput_rpm{" .. labels .. ",window=\"5m\"} " .. (route_metrics.m5 or 0))
                ngx.say("ossfe_proxy_route_throughput_rpm{" .. labels .. ",window=\"15m\"} " .. (route_metrics.m15 or 0))
                
                -- 错误吞吐量
                ngx.say("# HELP ossfe_proxy_route_errors_rpm Errors per minute")
                ngx.say("# TYPE ossfe_proxy_route_errors_rpm gauge")
                ngx.say("ossfe_proxy_route_errors_rpm{" .. labels .. ",window=\"1m\"} " .. (route_metrics.m1err or 0))
                ngx.say("ossfe_proxy_route_errors_rpm{" .. labels .. ",window=\"5m\"} " .. (route_metrics.m5err or 0))
                ngx.say("ossfe_proxy_route_errors_rpm{" .. labels .. ",window=\"15m\"} " .. (route_metrics.m15err or 0))
                
                -- 错误百分比
                ngx.say("# HELP ossfe_proxy_route_error_percentage Error percentage")
                ngx.say("# TYPE ossfe_proxy_route_error_percentage gauge")
                ngx.say("ossfe_proxy_route_error_percentage{" .. labels .. ",window=\"1m\"} " .. (route_metrics.m1errpct or 0))
                ngx.say("ossfe_proxy_route_error_percentage{" .. labels .. ",window=\"5m\"} " .. (route_metrics.m5errpct or 0))
                ngx.say("ossfe_proxy_route_error_percentage{" .. labels .. ",window=\"15m\"} " .. (route_metrics.m15errpct or 0))
                
                -- 延迟百分位数
                ngx.say("# HELP ossfe_proxy_route_latency_ms Request latency percentiles in milliseconds")
                ngx.say("# TYPE ossfe_proxy_route_latency_ms gauge")
                ngx.say("ossfe_proxy_route_latency_ms{" .. labels .. ",percentile=\"25\"} " .. (route_metrics.p25 or 0))
                ngx.say("ossfe_proxy_route_latency_ms{" .. labels .. ",percentile=\"50\"} " .. (route_metrics.p50 or 0))
                ngx.say("ossfe_proxy_route_latency_ms{" .. labels .. ",percentile=\"75\"} " .. (route_metrics.p75 or 0))
                ngx.say("ossfe_proxy_route_latency_ms{" .. labels .. ",percentile=\"95\"} " .. (route_metrics.p95 or 0))
                ngx.say("ossfe_proxy_route_latency_ms{" .. labels .. ",percentile=\"98\"} " .. (route_metrics.p98 or 0))
                ngx.say("ossfe_proxy_route_latency_ms{" .. labels .. ",percentile=\"99\"} " .. (route_metrics.p99 or 0))
                
                -- 请求时长统计
                ngx.say("# HELP ossfe_proxy_route_duration_ms Request duration statistics in milliseconds")
                ngx.say("# TYPE ossfe_proxy_route_duration_ms gauge")
                ngx.say("ossfe_proxy_route_duration_ms{" .. labels .. ",stat=\"min\"} " .. (route_metrics.min or 0))
                ngx.say("ossfe_proxy_route_duration_ms{" .. labels .. ",stat=\"mean\"} " .. (route_metrics.mean or 0))
                ngx.say("ossfe_proxy_route_duration_ms{" .. labels .. ",stat=\"max\"} " .. (route_metrics.max or 0))
            else
                ngx.log(ngx.ERR, "Failed to get metrics for route " .. name .. ": " .. (route_metrics or "unknown error"))
            end
        end
    end
    
    -- 上游指标
    for upstream_key, upstream_data in pairs(all_upstreams or {}) do
        local namespace = upstream_data.metadata and upstream_data.metadata.namespace or "default"
        local name = upstream_data.metadata and upstream_data.metadata.name or "unknown"
        
        local upstream_metrics_ok, upstream_metrics = pcall(metrics.get_metrics, "upstream", namespace, name)
        if upstream_metrics_ok and upstream_metrics then
            local labels = string.format('upstream="%s",namespace="%s"', name, namespace)
            
            -- 请求总数
            ngx.say("# HELP ossfe_proxy_upstream_requests_total Total number of requests")
            ngx.say("# TYPE ossfe_proxy_upstream_requests_total counter")
            ngx.say("ossfe_proxy_upstream_requests_total{" .. labels .. "} " .. (upstream_metrics.cnt or 0))
            
            -- 吞吐量指标
            ngx.say("# HELP ossfe_proxy_upstream_throughput_rpm Requests per minute")
            ngx.say("# TYPE ossfe_proxy_upstream_throughput_rpm gauge")
            ngx.say("ossfe_proxy_upstream_throughput_rpm{" .. labels .. ",window=\"1m\"} " .. (upstream_metrics.m1 or 0))
            ngx.say("ossfe_proxy_upstream_throughput_rpm{" .. labels .. ",window=\"5m\"} " .. (upstream_metrics.m5 or 0))
            ngx.say("ossfe_proxy_upstream_throughput_rpm{" .. labels .. ",window=\"15m\"} " .. (upstream_metrics.m15 or 0))
            
            -- 错误吞吐量
            ngx.say("# HELP ossfe_proxy_upstream_errors_rpm Errors per minute")
            ngx.say("# TYPE ossfe_proxy_upstream_errors_rpm gauge")
            ngx.say("ossfe_proxy_upstream_errors_rpm{" .. labels .. ",window=\"1m\"} " .. (upstream_metrics.m1err or 0))
            ngx.say("ossfe_proxy_upstream_errors_rpm{" .. labels .. ",window=\"5m\"} " .. (upstream_metrics.m5err or 0))
            ngx.say("ossfe_proxy_upstream_errors_rpm{" .. labels .. ",window=\"15m\"} " .. (upstream_metrics.m15err or 0))
            
            -- 错误百分比
            ngx.say("# HELP ossfe_proxy_upstream_error_percentage Error percentage")
            ngx.say("# TYPE ossfe_proxy_upstream_error_percentage gauge")
            ngx.say("ossfe_proxy_upstream_error_percentage{" .. labels .. ",window=\"1m\"} " .. (upstream_metrics.m1errpct or 0))
            ngx.say("ossfe_proxy_upstream_error_percentage{" .. labels .. ",window=\"5m\"} " .. (upstream_metrics.m5errpct or 0))
            ngx.say("ossfe_proxy_upstream_error_percentage{" .. labels .. ",window=\"15m\"} " .. (upstream_metrics.m15errpct or 0))
            
            -- 延迟百分位数
            ngx.say("# HELP ossfe_proxy_upstream_latency_ms Request latency percentiles in milliseconds")
            ngx.say("# TYPE ossfe_proxy_upstream_latency_ms gauge")
            ngx.say("ossfe_proxy_upstream_latency_ms{" .. labels .. ",percentile=\"25\"} " .. (upstream_metrics.p25 or 0))
            ngx.say("ossfe_proxy_upstream_latency_ms{" .. labels .. ",percentile=\"50\"} " .. (upstream_metrics.p50 or 0))
            ngx.say("ossfe_proxy_upstream_latency_ms{" .. labels .. ",percentile=\"75\"} " .. (upstream_metrics.p75 or 0))
            ngx.say("ossfe_proxy_upstream_latency_ms{" .. labels .. ",percentile=\"95\"} " .. (upstream_metrics.p95 or 0))
            ngx.say("ossfe_proxy_upstream_latency_ms{" .. labels .. ",percentile=\"98\"} " .. (upstream_metrics.p98 or 0))
            ngx.say("ossfe_proxy_upstream_latency_ms{" .. labels .. ",percentile=\"99\"} " .. (upstream_metrics.p99 or 0))
            
            -- 请求时长统计
            ngx.say("# HELP ossfe_proxy_upstream_duration_ms Request duration statistics in milliseconds")
            ngx.say("# TYPE ossfe_proxy_upstream_duration_ms gauge")
            ngx.say("ossfe_proxy_upstream_duration_ms{" .. labels .. ",stat=\"min\"} " .. (upstream_metrics.min or 0))
            ngx.say("ossfe_proxy_upstream_duration_ms{" .. labels .. ",stat=\"mean\"} " .. (upstream_metrics.mean or 0))
            ngx.say("ossfe_proxy_upstream_duration_ms{" .. labels .. ",stat=\"max\"} " .. (upstream_metrics.max or 0))
        else
            ngx.log(ngx.ERR, "Failed to get metrics for upstream " .. name .. ": " .. (upstream_metrics or "unknown error"))
        end
    end
end