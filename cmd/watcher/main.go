package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

const (
	openrestyAPIBase = "http://127.0.0.1:9180"
)

var (
	routeGVR = schema.GroupVersionResource{
		Group:    "ossfe.imvictor.tech",
		Version:  "v1",
		Resource: "ossproxyroutes",
	}
	upstreamGVR = schema.GroupVersionResource{
		Group:    "ossfe.imvictor.tech",
		Version:  "v1",
		Resource: "ossproxyupstreams",
	}
)

type Watcher struct {
	client    dynamic.Interface
	clientset kubernetes.Interface
	ctx       context.Context
	cancel    context.CancelFunc
	apiKey    string
}

func NewWatcher() (*Watcher, error) {
	config, err := rest.InClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("failed to get in-cluster config: %v", err)
	}

	client, err := dynamic.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create dynamic client: %v", err)
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create kubernetes clientset: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())

	// 读取内部 API 认证密钥
	apiKeyFile := "/tmp/api.key"
	apiKeyBytes, err := os.ReadFile(apiKeyFile)
	if err != nil {
		return nil, fmt.Errorf("failed to read API key from %s: %v", apiKeyFile, err)
	}
	apiKey := string(bytes.TrimSpace(apiKeyBytes))
	if apiKey == "" {
		return nil, fmt.Errorf("API key is empty")
	}
	log.Printf("Loaded internal API key: %s...", apiKey[:8])

	return &Watcher{
		client:    client,
		clientset: clientset,
		ctx:       ctx,
		cancel:    cancel,
		apiKey:    apiKey,
	}, nil
}

func (w *Watcher) Start() error {
	log.Println("Starting CRD watcher...")

	// 启动 admission webhook（如果启用）
	var webhookServer *WebhookServer
	if webhookEnabled := os.Getenv("WEBHOOK_ENABLED"); webhookEnabled == "true" {
		webhookPort, _ := strconv.Atoi(getEnvOrDefault("WEBHOOK_PORT", "8443"))
		certPath := getEnvOrDefault("WEBHOOK_CERT_PATH", "/tmp/webhook-certs/tls.crt")
		keyPath := getEnvOrDefault("WEBHOOK_KEY_PATH", "/tmp/webhook-certs/tls.key")

		// 检查证书文件是否存在
		if err := validateCertFiles(certPath, keyPath); err != nil {
			log.Printf("Webhook certificate files validation failed: %v", err)
			return err
		}

		webhookServer = NewWebhookServer(w, webhookPort, certPath, keyPath)
		go func() {
			if err := webhookServer.Start(); err != nil {
				log.Printf("Webhook server failed: %v", err)
			}
		}()
		log.Printf("Admission webhook started on port %d", webhookPort)
	}

	// 等待 OpenResty 启动
	if err := w.waitForOpenResty(); err != nil {
		log.Printf("Failed to connect to OpenResty: %v", err)
		return err
	}

	// 初始全量同步 - 这是关键步骤，完成后 Lua 侧才会 ready
	log.Println("Performing initial full sync...")
	if err := w.syncAll(); err != nil {
		log.Printf("Initial sync failed: %v", err)
		return err
	}
	log.Println("Initial sync completed, OpenResty should be ready now")

	// 启动 watch goroutines
	go w.watchRoutes()
	go w.watchUpstreams()

	// 等待信号
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	select {
	case sig := <-sigCh:
		log.Printf("Received signal %v, shutting down...", sig)
		w.cancel()
		if webhookServer != nil {
			webhookServer.Stop()
		}
	case <-w.ctx.Done():
		log.Println("Context cancelled, shutting down...")
		if webhookServer != nil {
			webhookServer.Stop()
		}
	}

	return nil
}

func getEnvOrDefault(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

// validateCertFiles 检查证书文件是否存在且可读
func validateCertFiles(certPath, keyPath string) error {
	// 检查证书文件
	if _, err := os.Stat(certPath); os.IsNotExist(err) {
		return fmt.Errorf("certificate file not found: %s", certPath)
	}

	// 检查私钥文件
	if _, err := os.Stat(keyPath); os.IsNotExist(err) {
		return fmt.Errorf("private key file not found: %s", keyPath)
	}

	// 尝试加载证书验证格式是否正确
	if _, err := tls.LoadX509KeyPair(certPath, keyPath); err != nil {
		return fmt.Errorf("failed to load certificate pair: %v", err)
	}

	log.Printf("Webhook certificates validated successfully: cert=%s, key=%s", certPath, keyPath)
	return nil
}

func (w *Watcher) waitForOpenResty() error {
	log.Println("Waiting for OpenResty to be ready...")

	timeout := time.After(30 * time.Second)
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-timeout:
			return fmt.Errorf("timeout waiting for OpenResty")
		case <-ticker.C:
			// 尝试连接 OpenResty health 端点
			client := &http.Client{Timeout: 2 * time.Second}
			resp, err := client.Get(openrestyAPIBase + "/")
			if err == nil && resp.StatusCode == http.StatusOK {
				resp.Body.Close()
				log.Println("OpenResty is ready")
				return nil
			}
			if resp != nil {
				resp.Body.Close()
			}
		}
	}
}

func (w *Watcher) syncAll() error {
	// 同步所有 routes
	routes, err := w.client.Resource(routeGVR).List(w.ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("failed to list routes: %v", err)
	}

	syncErrors := 0
	for _, route := range routes.Items {
		if err := w.notifyOpenresty("POST", "/api/routes/update", &route); err != nil {
			log.Printf("Failed to sync route %s: %v", route.GetName(), err)
			syncErrors++
		}
	}
	log.Printf("Synced %d/%d routes successfully", len(routes.Items)-syncErrors, len(routes.Items))

	// 同步所有 upstreams
	upstreams, err := w.client.Resource(upstreamGVR).List(w.ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("failed to list upstreams: %v", err)
	}

	for _, upstream := range upstreams.Items {
		if err := w.notifyOpenresty("POST", "/api/upstreams/update", &upstream); err != nil {
			log.Printf("Failed to sync upstream %s: %v", upstream.GetName(), err)
			syncErrors++
		}

		// 级联同步 upstream 引用的 secret
		if err := w.syncUpstreamSecrets(&upstream); err != nil {
			log.Printf("Failed to sync secrets for upstream %s: %v", upstream.GetName(), err)
			syncErrors++
		}
	}
	log.Printf("Synced %d/%d upstreams successfully", len(upstreams.Items)-syncErrors, len(upstreams.Items))

	if syncErrors > 0 {
		return fmt.Errorf("failed to sync %d resources", syncErrors)
	}

	return nil
}

func (w *Watcher) watchRoutes() {
	for {
		select {
		case <-w.ctx.Done():
			return
		default:
			if err := w.watchResource(routeGVR, "routes"); err != nil {
				log.Printf("Route watch failed: %v, retrying in 5 seconds...", err)
				time.Sleep(5 * time.Second)
			}
		}
	}
}

func (w *Watcher) watchUpstreams() {
	for {
		select {
		case <-w.ctx.Done():
			return
		default:
			if err := w.watchResource(upstreamGVR, "upstreams"); err != nil {
				log.Printf("Upstream watch failed: %v, retrying in 5 seconds...", err)
				time.Sleep(5 * time.Second)
			}
		}
	}
}

func (w *Watcher) watchResource(gvr schema.GroupVersionResource, resourceType string) error {
	log.Printf("Starting watch for %s", resourceType)

	watchInterface, err := w.client.Resource(gvr).Watch(w.ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("failed to start watch: %v", err)
	}
	defer watchInterface.Stop()

	for {
		select {
		case <-w.ctx.Done():
			return nil
		case event, ok := <-watchInterface.ResultChan():
			if !ok {
				return fmt.Errorf("watch channel closed")
			}

			if err := w.handleEvent(event, resourceType); err != nil {
				log.Printf("Failed to handle %s event: %v", resourceType, err)
			}
		}
	}
}

func (w *Watcher) handleEvent(event watch.Event, resourceType string) error {
	obj, ok := event.Object.(*unstructured.Unstructured)
	if !ok {
		return fmt.Errorf("unexpected object type: %T", event.Object)
	}

	name := obj.GetName()
	namespace := obj.GetNamespace()
	if namespace == "" {
		namespace = "default"
	}

	log.Printf("Received %s event for %s %s/%s", event.Type, resourceType, namespace, name)

	var endpoint string
	switch event.Type {
	case watch.Added, watch.Modified:
		if resourceType == "routes" {
			endpoint = "/api/routes/update"
		} else {
			endpoint = "/api/upstreams/update"
		}

		// 对于 upstream 事件，需要级联同步相关的 secret
		if resourceType == "upstreams" {
			if err := w.syncUpstreamSecrets(obj); err != nil {
				log.Printf("Failed to sync secrets for upstream %s: %v", name, err)
			}
		}

	case watch.Deleted:
		if resourceType == "routes" {
			endpoint = "/api/routes/delete"
		} else {
			endpoint = "/api/upstreams/delete"
		}
	default:
		log.Printf("Unknown event type: %s", event.Type)
		return nil
	}

	return w.notifyOpenresty("POST", endpoint, obj)
}

func (w *Watcher) notifyOpenresty(method, path string, obj *unstructured.Unstructured) error {
	data, err := json.Marshal(obj)
	if err != nil {
		return fmt.Errorf("failed to marshal object: %v", err)
	}

	url := openrestyAPIBase + path
	req, err := http.NewRequest(method, url, bytes.NewBuffer(data))
	if err != nil {
		return fmt.Errorf("failed to create request: %v", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-API-Key", w.apiKey)

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("failed to make request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("request failed with status %d", resp.StatusCode)
	}

	return nil
}

// syncUpstreamSecrets 级联同步 upstream 引用的 secret
func (w *Watcher) syncUpstreamSecrets(upstream *unstructured.Unstructured) error {
	// 提取 secretRef 信息
	credentials, found, err := unstructured.NestedMap(upstream.Object, "spec", "credentials")
	if err != nil {
		return fmt.Errorf("failed to get credentials: %v", err)
	}
	if !found {
		// 没有配置凭据，不需要同步 secret
		return nil
	}

	secretRef, found, err := unstructured.NestedMap(credentials, "secretRef")
	if err != nil {
		return fmt.Errorf("failed to get secretRef: %v", err)
	}
	if !found {
		// 没有引用 secret，不需要同步
		return nil
	}

	// 获取 secret 名称和命名空间
	secretName, found, err := unstructured.NestedString(secretRef, "name")
	if err != nil || !found {
		return fmt.Errorf("secretRef missing name field")
	}

	secretNamespace, found, err := unstructured.NestedString(secretRef, "namespace")
	if err != nil || !found {
		// 如果没有指定命名空间，使用 upstream 的命名空间
		secretNamespace = upstream.GetNamespace()
		if secretNamespace == "" {
			secretNamespace = "default"
		}
	}

	log.Printf("Syncing secret %s/%s for upstream %s", secretNamespace, secretName, upstream.GetName())

	// 获取 secret
	secret, err := w.clientset.CoreV1().Secrets(secretNamespace).Get(w.ctx, secretName, metav1.GetOptions{})
	if err != nil {
		return fmt.Errorf("failed to get secret %s/%s: %v", secretNamespace, secretName, err)
	}

	// 转换为 unstructured 格式并同步到 Lua
	secretUnstructured := &unstructured.Unstructured{}
	secretUnstructured.SetAPIVersion("v1")
	secretUnstructured.SetKind("Secret")
	secretUnstructured.SetName(secret.Name)
	secretUnstructured.SetNamespace(secret.Namespace)
	secretUnstructured.SetUID(secret.UID)
	secretUnstructured.SetResourceVersion(secret.ResourceVersion)

	// 设置 data 字段
	if secret.Data != nil {
		data := make(map[string]interface{})
		for key, value := range secret.Data {
			data[key] = string(value)
		}
		unstructured.SetNestedMap(secretUnstructured.Object, data, "data")
	}

	return w.notifyOpenresty("POST", "/api/secrets/update", secretUnstructured)
}

func main() {
	watcher, err := NewWatcher()
	if err != nil {
		log.Fatalf("Failed to create watcher: %v", err)
	}

	if err := watcher.Start(); err != nil {
		log.Fatalf("Watcher failed: %v", err)
	}
}
