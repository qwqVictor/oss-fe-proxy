# 使用 OpenResty 官方镜像作为基础镜像
FROM reg.imvictor.tech/hub/openresty/openresty:1.27.1.2-3-bookworm-fat

# 设置维护者信息
LABEL maintainer="i@qwq.ren"
LABEL description="OSS Frontend Proxy based on OpenResty"

# 安装必要的包
RUN apt-get update && \
    apt-get install -y \
        ca-certificates \
        curl \
        git \
        wget \
        unzip \
        openssl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 安装 Lua resty 库（用 OPM）
RUN /usr/local/openresty/bin/opm install ledgetech/lua-resty-http \
    && /usr/local/openresty/bin/opm install openresty/lua-resty-string \
    && /usr/local/openresty/bin/opm install openresty/lua-resty-lrucache

# 创建必要的目录
RUN mkdir -p /usr/local/openresty/lua \
    && mkdir -p /var/log/nginx \
    && mkdir -p /var/cache/nginx \
    && mkdir -p /etc/nginx/ssl

# 复制 Lua 脚本
COPY lua/ /usr/local/openresty/lua/

# 复制 nginx 配置
COPY nginx/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

# 创建启动脚本
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 创建 nginx 用户和组
#RUN addgroup --gid 101 nginx \
#    && adduser --system --uid 101 --gid 101 --home /var/cache/nginx --shell /usr/sbin/nologin nginx

# 设置正确的权限
#RUN chown -R nginx:nginx /var/log/nginx \
#    && chown -R nginx:nginx /var/cache/nginx \
 #   && chown -R nginx:nginx /usr/local/openresty/nginx/ \
 #   && chmod 755 /usr/local/openresty/lua/*.lua

# 健康检查
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

# 暴露端口
EXPOSE 80

# 设置工作目录
WORKDIR /usr/local/openresty

# 使用非 root 用户运行（可选，根据安全需求决定）
# USER nginx

# 启动服务
ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]