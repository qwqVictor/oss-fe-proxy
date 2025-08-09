#!/bin/bash

# 生成 100 年有效期的自签名证书用于 webhook

set -e

CERT_DIR="./certs"
DEPLOY_DIR="./deploy"
mkdir -p $CERT_DIR

echo "生成证书文件..."

# 创建 CA 私钥
openssl genrsa -out $CERT_DIR/ca.key 4096

# 创建 CA 证书 (100 年有效期)
openssl req -new -x509 -key $CERT_DIR/ca.key -sha256 -subj "/C=CN/ST=Beijing/L=Beijing/O=OSS-FE-Proxy/CN=oss-fe-proxy-ca" -days 36500 -out $CERT_DIR/ca.crt

# 创建 webhook 服务的私钥
openssl genrsa -out $CERT_DIR/webhook.key 4096

# 创建 webhook 服务的证书签名请求
openssl req -new -key $CERT_DIR/webhook.key -out $CERT_DIR/webhook.csr -subj "/C=CN/ST=Beijing/L=Beijing/O=OSS-FE-Proxy/CN=oss-fe-proxy-webhook.oss-fe-proxy.svc"

# 创建扩展配置文件
cat > $CERT_DIR/webhook.ext << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = oss-fe-proxy-webhook
DNS.2 = oss-fe-proxy-webhook.oss-fe-proxy
DNS.3 = oss-fe-proxy-webhook.oss-fe-proxy.svc
DNS.4 = oss-fe-proxy-webhook.oss-fe-proxy.svc.cluster.local
EOF

# 使用 CA 签名 webhook 证书 (100 年有效期)
openssl x509 -req -in $CERT_DIR/webhook.csr -CA $CERT_DIR/ca.crt -CAkey $CERT_DIR/ca.key -CAcreateserial -out $CERT_DIR/webhook.crt -days 36500 -sha256 -extfile $CERT_DIR/webhook.ext

echo "创建 Secret YAML 文件..."

# 创建包含证书的 Secret YAML 文件
cat > $DEPLOY_DIR/webhook-certs.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: oss-fe-proxy-webhook-certs
  namespace: oss-fe-proxy
  labels:
    app: oss-fe-proxy
type: Opaque
stringData:
  tls.crt: |
$(sed 's/^/    /' $CERT_DIR/webhook.crt)
  tls.key: |
$(sed 's/^/    /' $CERT_DIR/webhook.key)
  ca.crt: |
$(sed 's/^/    /' $CERT_DIR/ca.crt)
EOF

echo "更新 webhook.yaml 中的 CA Bundle..."

# 获取 CA 证书的 base64 编码
CA_BUNDLE=$(base64 -w 0 $CERT_DIR/ca.crt)

# 替换 webhook.yaml 中的 CA_BUNDLE 占位符
if [ -f "$DEPLOY_DIR/webhook.yaml" ]; then
    sed -i "s/<CA_BUNDLE>/$CA_BUNDLE/g" $DEPLOY_DIR/webhook.yaml
    echo "已更新 webhook.yaml 中的 CA Bundle"
else
    echo "警告: webhook.yaml 文件不存在"
fi

# 验证证书
echo ""
echo "Certificate verification:"
openssl verify -CAfile $CERT_DIR/ca.crt $CERT_DIR/webhook.crt

# 显示证书信息
echo ""
echo "Certificate details:"
openssl x509 -in $CERT_DIR/webhook.crt -text -noout | grep -A 2 "Validity"

echo ""
echo "✅ 证书生成完成！"
echo "📁 生成的文件:"
echo "   - $DEPLOY_DIR/webhook-certs.yaml (Secret 配置)"
echo "   - $DEPLOY_DIR/webhook.yaml (已更新 CA Bundle)"
echo "   - $CERT_DIR/ (证书文件)"
