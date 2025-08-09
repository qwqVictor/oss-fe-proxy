#!/bin/sh
set -e

if [ -z "$LOG_LEVEL" ]; then
    LOG_LEVEL="warn"
fi
if [ -z "$ACCESS_LOG_FILE" ]; then
    ACCESS_LOG_FILE="/dev/null"
fi

# 生成内部 API 认证密钥
API_KEY_FILE="/tmp/api.key"
if [ ! -f "$API_KEY_FILE" ]; then
    # 生成 32 字节的随机密钥（Base64 编码）
    INTERNAL_API_KEY=$(head -c 32 /dev/urandom | base64 | tr -d '=\n')
    echo "$INTERNAL_API_KEY" > "$API_KEY_FILE"
fi

# 打印启动信息
echo "Starting OSS Frontend Proxy with Go Watcher..."
echo "Kubernetes API Server: ${KUBERNETES_SERVICE_HOST:-not-detected}"
echo "Namespace: ${POD_NAMESPACE:-default}"
echo "Log Level: ${LOG_LEVEL}"
echo "Access Log File: ${ACCESS_LOG_FILE}"

sed -i "s!%ENV_LOG_LEVEL%!${LOG_LEVEL}!g" /usr/local/openresty/nginx/conf/nginx.conf
sed -i "s!%ENV_ACCESS_LOG_FILE%!${ACCESS_LOG_FILE}!g" /usr/local/openresty/nginx/conf/nginx.conf

# 检查必要的环境变量
if [ -z "$KUBERNETES_SERVICE_HOST" ]; then
    echo "Warning: KUBERNETES_SERVICE_HOST not set, running outside Kubernetes cluster"
fi

# 检查 ServiceAccount token 是否存在
if [ ! -f "/var/run/secrets/kubernetes.io/serviceaccount/token" ]; then
    echo "Warning: Kubernetes ServiceAccount token not found"
    echo "Make sure the pod has proper RBAC permissions to access CRDs"
fi

# 检查 nginx 配置
echo "Testing nginx configuration..."
/usr/local/openresty/nginx/sbin/nginx -t

if [ $? -eq 0 ]; then
    echo "Nginx configuration test passed"
else
    echo "Nginx configuration test failed"
    exit 1
fi

# 创建 PID 目录
mkdir -p /var/run/nginx

# 如果是 supervisord 命令，则启动多进程管理
if [ "$1" = "supervisord" ]; then
    echo "Starting supervisord (OpenResty + CRD Watcher)..."
    exec supervisord -c /etc/supervisor/conf.d/supervisord.conf
fi

# 如果是 nginx 命令，则只启动 nginx（用于调试）
if [ "$1" = "nginx" ]; then
    echo "Starting nginx only..."
    exec /usr/local/openresty/nginx/sbin/nginx -g "daemon off;"
fi

# 如果是 watcher 命令，则只启动 Go watcher（用于调试）
if [ "$1" = "watcher" ]; then
    echo "Starting CRD watcher only..."
    exec /usr/local/bin/crd-watcher
fi

# 否则执行传入的命令
exec "$@"