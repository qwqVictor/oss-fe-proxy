-- metrics.lua - 指标收集和统计模块

local json = require "cjson"

local _M = {}

-- 共享字典
local metrics_dict = ngx.shared.metrics
local counters_dict = ngx.shared.counters

-- 检查共享字典是否可用
if not metrics_dict then
    ngx.log(ngx.ERR, "metrics shared dict not available")
end
if not counters_dict then
    ngx.log(ngx.ERR, "counters shared dict not available")
end

-- 常量配置
local WINDOW_SIZE = 900  -- 15分钟窗口
local BUCKET_SIZE = 5    -- 5秒桶
local BUCKETS_COUNT = WINDOW_SIZE / BUCKET_SIZE  -- 180个桶
local LATENCY_BUCKETS = 1000  -- 延迟分布桶数

-- 指标键前缀
local COUNTER_PREFIX = "cnt:"
local LATENCY_PREFIX = "lat:"
local ERROR_PREFIX = "err:"
local WINDOW_PREFIX = "win:"

-- 获取当前时间桶
local function get_current_bucket()
    return math.floor(ngx.now() / BUCKET_SIZE)
end

-- 获取指标键
local function get_metric_key(resource_type, namespace, name, metric_type, bucket)
    if bucket then
        return string.format("%s%s:%s:%s:%s:%d", 
            WINDOW_PREFIX, resource_type, namespace or "default", name, metric_type, bucket)
    else
        return string.format("%s%s:%s:%s", 
            metric_type, resource_type, namespace or "default", name)
    end
end

-- 记录请求开始
function _M.record_request_start(resource_type, namespace, name)
    local key = get_metric_key(resource_type, namespace, name, "start", nil)
    return ngx.ctx[key] or ngx.now()
end

-- 记录请求完成
function _M.record_request_end(resource_type, namespace, name, status_code, start_time)
    if not start_time then
        start_time = ngx.ctx[get_metric_key(resource_type, namespace, name, "start", nil)] or ngx.now()
    end
    
    local now = ngx.now()
    local duration = (now - start_time) * 1000  -- 转换为毫秒
    local bucket = get_current_bucket()
    local is_error = status_code >= 400
    
    -- 增加总计数器
    local counter_key = get_metric_key(resource_type, namespace, name, COUNTER_PREFIX, nil)
    counters_dict:incr(counter_key, 1, 0)
    
    -- 记录到时间窗口桶
    local request_key = get_metric_key(resource_type, namespace, name, "req", bucket)
    counters_dict:incr(request_key, 1, 0, 300)  -- 5分钟过期
    
    -- 记录错误
    if is_error then
        local error_counter_key = get_metric_key(resource_type, namespace, name, ERROR_PREFIX, nil)
        counters_dict:incr(error_counter_key, 1, 0)
        
        local error_key = get_metric_key(resource_type, namespace, name, "err", bucket)
        counters_dict:incr(error_key, 1, 0, 300)
    end
    
    -- 记录延迟数据
    _M.record_latency(resource_type, namespace, name, duration)
end

-- 记录延迟数据（简化版本，使用直方图近似）
function _M.record_latency(resource_type, namespace, name, duration_ms)
    -- 将延迟分桶存储（对数分布）
    local bucket_index = math.floor(math.log(math.max(duration_ms, 1)) / math.log(2) * 10)
    bucket_index = math.min(bucket_index, 200)  -- 限制最大桶数
    
    local latency_key = get_metric_key(resource_type, namespace, name, LATENCY_PREFIX, bucket_index)
    counters_dict:incr(latency_key, 1, 0)
    
    -- 简单统计：记录最小值、最大值、总和、数量用于计算平均值
    local stats_key = get_metric_key(resource_type, namespace, name, "stats", nil)
    local stats_data = metrics_dict:get(stats_key)
    local stats = {}
    
    if stats_data then
        stats = json.decode(stats_data)
    else
        stats = {min = duration_ms, max = duration_ms, sum = 0, count = 0}
    end
    
    stats.min = math.min(stats.min, duration_ms)
    stats.max = math.max(stats.max, duration_ms)
    stats.sum = stats.sum + duration_ms
    stats.count = stats.count + 1
    
    metrics_dict:set(stats_key, json.encode(stats), 86400)  -- 24小时过期
end

-- 计算时间窗口内的统计数据
local function calculate_window_stats(resource_type, namespace, name, window_minutes)
    if not counters_dict then
        return {throughput = 0, error_throughput = 0, error_percentage = 0}
    end
    
    local current_bucket = get_current_bucket()
    local buckets_in_window = window_minutes * 60 / BUCKET_SIZE
    local total_requests = 0
    local total_errors = 0
    
    -- 遍历窗口内的所有桶
    for i = 0, buckets_in_window - 1 do
        local bucket = current_bucket - i
        
        -- 请求数
        local req_key = get_metric_key(resource_type, namespace, name, "req", bucket)
        local req_count = counters_dict:get(req_key) or 0
        total_requests = total_requests + req_count
        
        -- 错误数
        local err_key = get_metric_key(resource_type, namespace, name, "err", bucket)
        local err_count = counters_dict:get(err_key) or 0
        total_errors = total_errors + err_count
    end
    
    -- 计算每分钟平均值
    local avg_throughput = total_requests / window_minutes
    local avg_error_throughput = total_errors / window_minutes
    local error_percentage = total_requests > 0 and (total_errors / total_requests * 100) or 0
    
    return {
        throughput = avg_throughput,
        error_throughput = avg_error_throughput,
        error_percentage = error_percentage
    }
end

-- 计算延迟百分位数（简化版本）
local function calculate_latency_percentiles(resource_type, namespace, name)
    local percentiles = {25, 50, 75, 95, 98, 99}
    local result = {}
    
    if not counters_dict then
        for _, p in ipairs(percentiles) do
            result["p" .. p] = 0
        end
        return result
    end
    
    -- 收集所有延迟桶的数据
    local total_count = 0
    local buckets = {}
    
    for i = 0, 200 do
        local latency_key = get_metric_key(resource_type, namespace, name, LATENCY_PREFIX, i)
        local count = counters_dict:get(latency_key) or 0
        if count > 0 then
            buckets[i] = count
            total_count = total_count + count
        end
    end
    
    if total_count == 0 then
        for _, p in ipairs(percentiles) do
            result["p" .. p] = 0
        end
        return result
    end
    
    -- 计算百分位数（简化算法）
    local sorted_buckets = {}
    for bucket, count in pairs(buckets) do
        table.insert(sorted_buckets, {bucket = bucket, count = count})
    end
    table.sort(sorted_buckets, function(a, b) return a.bucket < b.bucket end)
    
    local cumulative = 0
    for _, p in ipairs(percentiles) do
        local target = total_count * p / 100
        for _, item in ipairs(sorted_buckets) do
            cumulative = cumulative + item.count
            if cumulative >= target then
                -- 将桶索引转换回延迟值（近似）
                result["p" .. p] = math.pow(2, item.bucket / 10)
                break
            end
        end
    end
    
    return result
end

-- 获取资源的所有指标
function _M.get_metrics(resource_type, namespace, name)
    -- 检查参数
    if not resource_type or not namespace or not name then
        return {cnt = 0, m1 = 0, m5 = 0, m15 = 0, m1err = 0, m5err = 0, m15err = 0, 
                m1errpct = 0, m5errpct = 0, m15errpct = 0, p25 = 0, p50 = 0, p75 = 0, 
                p95 = 0, p98 = 0, p99 = 0, min = 0, mean = 0, max = 0}
    end
    
    -- 检查共享字典
    if not counters_dict or not metrics_dict then
        return {cnt = 0, m1 = 0, m5 = 0, m15 = 0, m1err = 0, m5err = 0, m15err = 0, 
                m1errpct = 0, m5errpct = 0, m15errpct = 0, p25 = 0, p50 = 0, p75 = 0, 
                p95 = 0, p98 = 0, p99 = 0, min = 0, mean = 0, max = 0}
    end
    
    -- 总计数器
    local counter_key = get_metric_key(resource_type, namespace, name, COUNTER_PREFIX, nil)
    local total_count = counters_dict:get(counter_key) or 0
    
    local error_counter_key = get_metric_key(resource_type, namespace, name, ERROR_PREFIX, nil)
    local total_errors = counters_dict:get(error_counter_key) or 0
    
    -- 时间窗口统计
    local m1_stats = calculate_window_stats(resource_type, namespace, name, 1)
    local m5_stats = calculate_window_stats(resource_type, namespace, name, 5)
    local m15_stats = calculate_window_stats(resource_type, namespace, name, 15)
    
    -- 延迟统计
    local latency_percentiles = calculate_latency_percentiles(resource_type, namespace, name)
    
    -- 基础统计
    local stats_key = get_metric_key(resource_type, namespace, name, "stats", nil)
    local stats_data = metrics_dict and metrics_dict:get(stats_key)
    local stats = {min = 0, max = 0, sum = 0, count = 0}
    if stats_data then
        local ok, decoded = pcall(json.decode, stats_data)
        if ok and decoded then
            stats = decoded
        end
    end
    local mean = stats.count > 0 and (stats.sum / stats.count) or 0
    
    return {
        -- 计数
        cnt = total_count,
        
        -- 吞吐量 (requests per minute)
        m1 = m1_stats.throughput,
        m5 = m5_stats.throughput,
        m15 = m15_stats.throughput,
        
        -- 错误吞吐量
        m1err = m1_stats.error_throughput,
        m5err = m5_stats.error_throughput,
        m15err = m15_stats.error_throughput,
        
        -- 错误百分比
        m1errpct = m1_stats.error_percentage,
        m5errpct = m5_stats.error_percentage,
        m15errpct = m15_stats.error_percentage,
        
        -- 延迟百分位数 (ms)
        p25 = latency_percentiles.p25 or 0,
        p50 = latency_percentiles.p50 or 0,
        p75 = latency_percentiles.p75 or 0,
        p95 = latency_percentiles.p95 or 0,
        p98 = latency_percentiles.p98 or 0,
        p99 = latency_percentiles.p99 or 0,
        
        -- 请求时长统计 (ms)
        min = stats.min,
        mean = mean,
        max = stats.max
    }
end

-- 获取所有资源的指标
function _M.get_all_metrics()
    local result = {
        routes = {},
        upstreams = {}
    }
    
    -- 这里需要遍历所有已知的资源
    -- 实际实现中可能需要维护一个资源列表
    return result
end

return _M
