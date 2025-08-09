# OSS Frontend Proxy

基于 OpenResty 的 OSS 前端代理服务，通过 Kubernetes CRD 自动发现域名并反向代理到 OSS，为前端应用提供部署支持。

## 功能特性

- 🚀 **自动发现**: 通过 Kubernetes CRD 自动发现域名配置
- 🔄 **反向代理**: 将前端应用请求代理到 OSS 存储
- 🎯 **SPA 支持**: 支持单页应用（SPA）路由回退
- 📦 **缓存策略**: 可配置的缓存策略，优化性能
- 🔧 **灵活配置**: 支持多种 OSS 提供商（AWS S3、阿里云 OSS、腾讯云 COS 等）
- 🛡️ **安全认证**: 支持 OSS 访问凭据的安全管理
- 📊 **监控支持**: 内置健康检查和指标端点

## 架构概述

```
┌─────────────┐    HTTP API    ┌──────────────────┐
│             │◄──────────────►│                  │
│  OpenResty  │                │   Go Watcher     │
│  (Lua API)  │                │   (watch CRDs)   │
│             │                │                  │
└─────────────┘                └──────────────────┘
       │                               │
       │ Proxy Requests                │ K8S API
       ▼                               ▼
┌─────────────┐                ┌──────────────────┐
│             │                │                  │
│   OSS/S3    │                │  Kubernetes API  │
│             │                │                  │
└─────────────┘                └──────────────────┘
```

## 核心组件

### 1. CRD 定义

#### OSSProxyRoute
定义域名到 OSS 的路由规则：
- 支持多域名配置
- SPA 应用模式支持
- 自定义错误页面
- 缓存策略配置

#### OSSProxyUpstream
定义 OSS 访问配置：
- 多种 OSS 提供商支持
- 安全凭据管理
- 连接超时和重试策略

### 2. OpenResty 组件

- **crd_watcher.lua**: Kubernetes CRD 监听和配置获取
- **oss_proxy.lua**: OSS 代理逻辑和请求处理
- **nginx.conf**: Nginx 主配置文件

## 快速开始

### 1. 部署到 Kubernetes

```bash
kubectl create -f crds/
kubectl create -f deploy/
```

### 2. 配置 OSS 凭据

```bash
# 创建 OSS 访问凭据
kubectl create secret generic s3os-credentials \
  --from-literal=access-key-id=YOUR_ACCESS_KEY \
  --from-literal=secret-access-key=YOUR_SECRET_KEY \
  -n oss-fe-proxy
```

### 3. 创建 Upstream 配置

```yaml
apiVersion: ossfe.imvictor.tech/v1
kind: OSSProxyUpstream
metadata:
  name: my-oss-upstream
  namespace: oss-fe-proxy
spec:
  provider: "aws"
  region: "us-east-1"
  endpoint: "s3.amazonaws.com"
  useHTTPS: true
  pathStyle: false
  credentials:
    secretRef:
      name: s3os-credentials
      namespace: oss-fe-proxy
```

### 4. 创建路由配置

```yaml
apiVersion: ossfe.imvictor.tech/v1
kind: OSSProxyRoute
metadata:
  name: my-frontend-app
  namespace: oss-fe-proxy
spec:
  hosts:
    - "myapp.example.com"
  upstreamRef:
    name: my-oss-upstream
    namespace: oss-fe-proxy
  bucket: "my-frontend-bucket"
  indexFile: "index.html"
  spaApp: true
  cache:
    enabled: true
    htmlMaxAge: 300
    staticMaxAge: 86400
```

## 配置说明

### OSSProxyRoute 配置选项

| 字段 | 类型 | 必需 | 描述 |
|------|------|------|------|
| `hosts` | array | ✅ | 域名列表 |
| `upstreamRef` | object | ✅ | 引用的 OSS Upstream |
| `bucket` | string | ✅ | OSS bucket 名称 |
| `prefix` | string | ❌ | 对象前缀路径 |
| `indexFile` | string | ❌ | 默认索引文件（默认: index.html） |
| `spaApp` | boolean | ❌ | SPA 模式（默认: false） |
| `errorPages` | object | ❌ | 自定义错误页面 |
| `cache` | object | ❌ | 缓存配置 |

### OSSProxyUpstream 配置选项

| 字段 | 类型 | 必需 | 描述 |
|------|------|------|------|
| `provider` | string | ✅ | OSS 提供商（aws/aliyun/tencent/minio/generic） |
| `region` | string | ✅ | OSS 区域 |
| `endpoint` | string | ✅ | OSS 端点 URL |
| `useHTTPS` | boolean | ❌ | 是否使用 HTTPS（默认: true） |
| `pathStyle` | boolean | ❌ | 是否使用路径样式（默认: false） |
| `credentials` | object | ✅ | 访问凭据配置 |
| `timeout` | object | ❌ | 超时配置 |
| `retry` | object | ❌ | 重试配置 |

## SPA 应用支持

启用 `spaApp: true` 时，当请求的文件不存在（404）时，系统会返回 `indexFile` 的内容并保持 200 状态码，这样可以让前端路由接管处理。

```yaml
spec:
  spaApp: true  # 启用 SPA 模式
  indexFile: "index.html"
```

## 缓存策略

可以为不同类型的文件配置不同的缓存时间：

```yaml
spec:
  cache:
    enabled: true
    maxAge: 3600        # 默认缓存时间
    htmlMaxAge: 300     # HTML 文件缓存时间
    staticMaxAge: 86400 # 静态文件缓存时间
```

## 监控和运维

### 健康检查

```bash
curl http://your-proxy:9181/healthz
```

### 指标监控

```bash
curl http://your-proxy:9181/metrics
```

### 查看日志

```bash
kubectl logs -f deployment/oss-fe-proxy -n oss-fe-proxy
```

### 调试命令

```bash
# 查看 CRD 资源
kubectl get ossproxyroutes,ossproxyupstreams -A

# 查看特定资源详情
kubectl describe ossproxyroute my-frontend-app -n oss-fe-proxy

# 查看 Pod 状态
kubectl get pods -n oss-fe-proxy -o wide
```

## 故障排除

### 常见问题

1. **无法连接到 OSS**
   - 检查网络连接
   - 验证凭据是否正确
   - 检查 endpoint 配置

2. **404 错误**
   - 确认 bucket 和对象路径正确
   - 检查 OSS 权限设置
   - 验证文件是否存在

3. **CRD 不生效**
   - 检查 RBAC 权限
   - 查看 Pod 日志
   - 验证 CRD 格式

### 日志分析

关键日志位置：
- Nginx 访问日志: `/var/log/nginx/access.log`
- Nginx 错误日志: `/var/log/nginx/error.log`
- Kubernetes 事件: `kubectl get events -n oss-fe-proxy`

## 安全考虑

1. **凭据管理**: 使用 Kubernetes Secret 存储敏感信息
2. **网络安全**: 配置适当的网络策略
3. **权限控制**: 最小化 RBAC 权限
4. **HTTPS**: 生产环境使用有效的 TLS 证书

## 性能优化

1. **缓存配置**: 根据业务需求调整缓存策略
2. **连接池**: 利用 OpenResty 的连接池功能
3. **资源限制**: 合理设置 CPU 和内存限制
4. **负载均衡**: 使用多副本部署

## 开发和贡献

### 本地开发

```bash
# 构建开发镜像
./scripts/build.sh -t dev

# 运行测试
./scripts/test.sh
```

### 项目结构

```
oss-fe-proxy/
├── crds/                 # CRD 定义
├── lua/                  # Lua 脚本
├── nginx/                # Nginx 配置
├── deploy/               # Kubernetes 部署文件
├── examples/             # 示例配置
├── scripts/              # 构建和部署脚本
└── Dockerfile            # 容器构建文件
```

## 许可证

Apache-2.0

## 更新日志

### v1.0.0
- 初始版本
- 支持基本的 OSS 代理功能
- CRD 配置管理
- SPA 应用支持
- 缓存策略配置