#!/bin/sh
set -e

if [ -z "$LOG_LEVEL" ]; then
    LOG_LEVEL="warn"
fi
if [ -z "$ACCESS_LOG_FILE" ]; then
    ACCESS_LOG_FILE="/dev/null"
fi

# 打印启动信息
echo "Starting OSS Frontend Proxy..."
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
    ln -s /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.addn.crt
else
    # 创建追加的 CA 证书
    cat /etc/ssl/certs/ca-certificates.crt /var/run/secrets/kubernetes.io/serviceaccount/ca.crt > /etc/ssl/certs/ca-certificates.addn.crt
    cert_md5="$(md5sum /var/run/secrets/kubernetes.io/serviceaccount/ca.crt | cut -f 1 -d ' ')"
    while true; do
        new_cert_md5="$(md5sum /var/run/secrets/kubernetes.io/serviceaccount/ca.crt | cut -f 1 -d ' ')"
        if [ "$cert_md5" != "$new_cert_md5" ]; then
            cert_md5="$new_cert_md5"
            cat /etc/ssl/certs/ca-certificates.crt /var/run/secrets/kubernetes.io/serviceaccount/ca.crt > /etc/ssl/certs/ca-certificates.addn.crt
        fi
        sleep 1
    done &
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

# 如果是 nginx 命令，则直接启动 nginx
if [ "$1" = "nginx" ]; then
    echo "Starting nginx..."
    /usr/local/openresty/nginx/sbin/nginx -g "daemon off;"
fi

# 否则执行传入的命令
"$@"