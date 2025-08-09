package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"

	admissionv1 "k8s.io/api/admission/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

type WebhookServer struct {
	server   *http.Server
	watcher  *Watcher
	certPath string
	keyPath  string
}

func NewWebhookServer(watcher *Watcher, port int, certPath, keyPath string) *WebhookServer {
	mux := http.NewServeMux()
	ws := &WebhookServer{
		watcher:  watcher,
		certPath: certPath,
		keyPath:  keyPath,
	}

	mux.HandleFunc("/validate", ws.handleValidate)
	mux.HandleFunc("/health", ws.handleHealth)

	ws.server = &http.Server{
		Addr:    fmt.Sprintf(":%d", port),
		Handler: mux,
	}

	return ws
}

func (ws *WebhookServer) Start() error {
	log.Printf("Starting webhook server on %s", ws.server.Addr)

	if ws.certPath != "" && ws.keyPath != "" {
		// HTTPS
		return ws.server.ListenAndServeTLS(ws.certPath, ws.keyPath)
	} else {
		// HTTP (for testing)
		return ws.server.ListenAndServe()
	}
}

func (ws *WebhookServer) Stop() error {
	return ws.server.Shutdown(context.Background())
}

func (ws *WebhookServer) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("OK"))
}

func (ws *WebhookServer) handleValidate(w http.ResponseWriter, r *http.Request) {
	log.Printf("Received validation request from %s", r.RemoteAddr)

	body, err := io.ReadAll(r.Body)
	if err != nil {
		log.Printf("Failed to read request body: %v", err)
		http.Error(w, "Failed to read request body", http.StatusBadRequest)
		return
	}

	var admissionReview admissionv1.AdmissionReview
	if err := json.Unmarshal(body, &admissionReview); err != nil {
		log.Printf("Failed to unmarshal admission review: %v", err)
		http.Error(w, "Failed to unmarshal admission review", http.StatusBadRequest)
		return
	}

	req := admissionReview.Request
	if req == nil {
		log.Printf("Admission review request is nil")
		http.Error(w, "Admission review request is nil", http.StatusBadRequest)
		return
	}

	response := ws.validateOSSProxyRoute(req)

	admissionResponse := &admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{
			APIVersion: "admission.k8s.io/v1",
			Kind:       "AdmissionReview",
		},
		Response: response,
	}

	respBytes, err := json.Marshal(admissionResponse)
	if err != nil {
		log.Printf("Failed to marshal admission response: %v", err)
		http.Error(w, "Failed to marshal admission response", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Write(respBytes)
}

func (ws *WebhookServer) validateOSSProxyRoute(req *admissionv1.AdmissionRequest) *admissionv1.AdmissionResponse {
	// 只处理 OSSProxyRoute 资源
	if req.Kind.Group != "ossfe.imvictor.tech" || req.Kind.Kind != "OSSProxyRoute" {
		return &admissionv1.AdmissionResponse{
			UID:     req.UID,
			Allowed: true,
		}
	}

	var route unstructured.Unstructured
	if err := json.Unmarshal(req.Object.Raw, &route); err != nil {
		log.Printf("Failed to unmarshal OSSProxyRoute: %v", err)
		return &admissionv1.AdmissionResponse{
			UID:     req.UID,
			Allowed: false,
			Result: &metav1.Status{
				Message: fmt.Sprintf("Failed to unmarshal OSSProxyRoute: %v", err),
			},
		}
	}

	// 提取域名列表
	hosts, found, err := unstructured.NestedStringSlice(route.Object, "spec", "hosts")
	if err != nil {
		log.Printf("Failed to get hosts from OSSProxyRoute: %v", err)
		return &admissionv1.AdmissionResponse{
			UID:     req.UID,
			Allowed: false,
			Result: &metav1.Status{
				Message: fmt.Sprintf("Failed to get hosts: %v", err),
			},
		}
	}

	if !found || len(hosts) == 0 {
		return &admissionv1.AdmissionResponse{
			UID:     req.UID,
			Allowed: false,
			Result: &metav1.Status{
				Message: "OSSProxyRoute must specify at least one host",
			},
		}
	}

	// 检查域名重复
	if err := ws.checkDuplicateHosts(hosts, route.GetName(), route.GetNamespace(), req.Operation); err != nil {
		log.Printf("Host validation failed: %v", err)
		return &admissionv1.AdmissionResponse{
			UID:     req.UID,
			Allowed: false,
			Result: &metav1.Status{
				Message: err.Error(),
			},
		}
	}

	return &admissionv1.AdmissionResponse{
		UID:     req.UID,
		Allowed: true,
	}
}

func (ws *WebhookServer) checkDuplicateHosts(hosts []string, routeName, routeNamespace string, operation admissionv1.Operation) error {
	// 获取所有现有的 OSSProxyRoute
	routes, err := ws.watcher.client.Resource(routeGVR).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("failed to list existing routes: %v", err)
	}

	// 收集所有现有域名及其所属的 route
	existingHosts := make(map[string]string) // host -> route_name/namespace

	for _, existingRoute := range routes.Items {
		// 跳过当前正在创建/更新的 route（对于 UPDATE 操作）
		if operation == admissionv1.Update &&
			existingRoute.GetName() == routeName &&
			existingRoute.GetNamespace() == routeNamespace {
			continue
		}

		existingHostList, found, err := unstructured.NestedStringSlice(existingRoute.Object, "spec", "hosts")
		if err != nil || !found {
			continue
		}

		routeKey := fmt.Sprintf("%s/%s", existingRoute.GetNamespace(), existingRoute.GetName())
		for _, host := range existingHostList {
			existingHosts[host] = routeKey
		}
	}

	// 检查新的域名是否有重复
	var conflicts []string
	for _, host := range hosts {
		if existingRoute, exists := existingHosts[host]; exists {
			conflicts = append(conflicts, fmt.Sprintf("host '%s' already used by route %s", host, existingRoute))
		}
	}

	if len(conflicts) > 0 {
		return fmt.Errorf("duplicate hosts detected: %s", strings.Join(conflicts, "; "))
	}

	// 检查当前 route 内部是否有重复域名
	hostSet := make(map[string]bool)
	for _, host := range hosts {
		if hostSet[host] {
			return fmt.Errorf("duplicate host '%s' within the same route", host)
		}
		hostSet[host] = true
	}

	return nil
}
