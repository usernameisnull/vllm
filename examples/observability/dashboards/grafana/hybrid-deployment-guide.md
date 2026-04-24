# Hybrid Deployment Guide: Prometheus/Grafana in K8s, vLLM Outside

A common scenario is running **Prometheus and Grafana inside Kubernetes** while **vLLM runs on a separate Linux machine** (bare metal, VM, or cloud instance). In this case, Prometheus Operator cannot automatically discover vLLM via pod labels. Instead, you must manually expose the external vLLM endpoint to Prometheus.

## Prerequisites

- Prometheus Operator (e.g., `kube-prometheus-stack`) running in Kubernetes
- Grafana Operator running in Kubernetes
- vLLM running on an external Linux host, accessible from the K8s cluster
- `kubectl` access to the target namespace

## vLLM Metrics Endpoint

Regardless of where vLLM runs, the metrics are always exposed at:

```
http://<vllm-host>:8000/metrics
```

Verify locally on the vLLM host:

```bash
curl http://localhost:8000/metrics | head
```

---

## Method 1: Service + Endpoints + ServiceMonitor (Recommended)

Prometheus Operator's `ServiceMonitor` only watches Kubernetes `Service` objects. To scrape an external target, create a **headless Service with manually defined Endpoints**.

### Step 1: Create a Headless Service (no selector)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: vllm-external
  namespace: monitoring          # Same namespace as your Prometheus instance
  labels:
    app: vllm-external
spec:
  ports:
    - name: metrics
      port: 8000
      protocol: TCP
  clusterIP: None                # Headless: no kube-proxy load balancing
```

### Step 2: Manually Define Endpoints

Point the Service to the actual IP of your vLLM host:

```yaml
apiVersion: v1
kind: Endpoints
metadata:
  name: vllm-external
  namespace: monitoring
subsets:
  - addresses:
      - ip: 192.168.1.100        # <-- Replace with your vLLM host IP
    ports:
      - name: metrics
        port: 8000
```

> **Why Endpoints instead of selector?** A normal Service uses `selector` to automatically populate Endpoints from matching Pods. Since vLLM is not a Pod, we create the Endpoints manually and leave the Service without a selector.

### Step 3: Create ServiceMonitor

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: vllm-external-metrics
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: vllm-external
  endpoints:
    - port: metrics
      path: /metrics
      interval: 5s
```

Apply all three resources:

```bash
kubectl apply -f vllm-external-service.yaml -n monitoring
```

### Step 4: Verify in Prometheus

1. Port-forward to your Prometheus UI:
   ```bash
   kubectl port-forward svc/prometheus-k8s 9090:9090 -n monitoring
   ```
2. Open `http://localhost:9090/targets`
3. Look for `vllm-external-metrics/vllm-external/0` — status should be **UP**

> **Firewall check:** Ensure the vLLM host allows inbound TCP on port `8000` from the Kubernetes cluster nodes (or the specific Prometheus Pod IP / node IP).

---

## Method 2: Prometheus `additionalScrapeConfigs`

If you prefer not to create fake K8s Services, you can add a static scrape config directly to your Prometheus CR:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: prometheus-k8s
  namespace: monitoring
spec:
  # ... existing spec ...
  additionalScrapeConfigs:
    - job_name: vllm-external
      static_configs:
        - targets:
            - '192.168.1.100:8000'
      metrics_path: /metrics
      scrape_interval: 5s
```

> **Trade-off:** Simpler, but less discoverable and not managed by `ServiceMonitor` resources.

---

## Summary: Which Method to Choose?

| Method | Use When | Pros | Cons |
|--------|---------|------|------|
| **Service + Endpoints + ServiceMonitor** | Standard hybrid deployment | K8s-native, fits GitOps, reusable pattern | Requires 3 extra YAML resources |
| **`additionalScrapeConfigs`** | Quick one-off setup, many external targets | Simple, minimal resources | Mixed with Prometheus CR, harder to maintain |

Both methods work with the Grafana dashboards in this repo. The Grafana datasource remains `http://prometheus-k8s.monitoring.svc.cluster.local:9090` (or your in-cluster Prometheus service URL).

---

## Importing the vLLM Dashboards

Once Prometheus is successfully scraping vLLM metrics, import the dashboard JSON files into Grafana.

### Option A: URL Reference (Simplest)

If your cluster has outbound internet access, reference the raw JSON directly from GitHub:

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: vllm-performance-dashboard
  namespace: monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  folder: "vLLM Monitoring"
  url: "https://raw.githubusercontent.com/vllm-project/vllm/main/examples/observability/dashboards/grafana/performance_statistics.json"
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: vllm-query-dashboard
  namespace: monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  folder: "vLLM Monitoring"
  url: "https://raw.githubusercontent.com/vllm-project/vllm/main/examples/observability/dashboards/grafana/query_statistics.json"
```

### Option B: ConfigMap Reference (Air-Gapped / Production)

If you cannot access GitHub from the cluster, store the JSON files in ConfigMaps and reference them.

**Step 1: Create ConfigMaps**

```bash
# Run from the directory containing the JSON files
kubectl create configmap vllm-performance-dashboard \
  --from-file=performance_statistics.json \
  -n monitoring

kubectl create configmap vllm-query-dashboard \
  --from-file=query_statistics.json \
  -n monitoring
```

**Step 2: Create GrafanaDashboard CRs**

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: vllm-performance-dashboard
  namespace: monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  folder: "vLLM Monitoring"
  configMapRef:
    name: vllm-performance-dashboard
    key: performance_statistics.json
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: vllm-query-dashboard
  namespace: monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  folder: "vLLM Monitoring"
  configMapRef:
    name: vllm-query-dashboard
    key: query_statistics.json
```

> **Note:** The `instanceSelector.matchLabels` must match the labels on your **Grafana** custom resource. Check with `kubectl get grafana -n <grafana-namespace> -o yaml | grep -A 5 "labels:"`.

---

## Complete All-in-One Manifest

Here is a single-file manifest that combines **Method 1 (Service + Endpoints + ServiceMonitor)** with **Option A (URL-based dashboards)** and the **GrafanaDatasource**:

```yaml
---
# 1. Headless Service (no selector) for external vLLM
apiVersion: v1
kind: Service
metadata:
  name: vllm-external
  namespace: monitoring
  labels:
    app: vllm-external
spec:
  ports:
    - name: metrics
      port: 8000
      protocol: TCP
  clusterIP: None
---
# 2. Manual Endpoints pointing to your external vLLM host
apiVersion: v1
kind: Endpoints
metadata:
  name: vllm-external
  namespace: monitoring
subsets:
  - addresses:
      - ip: 192.168.1.100        # <-- REPLACE WITH YOUR VLLM HOST IP
    ports:
      - name: metrics
        port: 8000
---
# 3. ServiceMonitor tells Prometheus to scrape the Service
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: vllm-external-metrics
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: vllm-external
  endpoints:
    - port: metrics
      path: /metrics
      interval: 5s
---
# 4. Grafana Datasource pointing to in-cluster Prometheus
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: prometheus
  namespace: monitoring
spec:
  datasource:
    name: Prometheus
    type: prometheus
    url: http://prometheus-k8s.monitoring.svc.cluster.local:9090
    access: proxy
    isDefault: true
  instanceSelector:
    matchLabels:
      dashboards: grafana
---
# 5. Performance Statistics Dashboard (URL reference)
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: vllm-performance-dashboard
  namespace: monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  folder: "vLLM Monitoring"
  url: "https://raw.githubusercontent.com/vllm-project/vllm/main/examples/observability/dashboards/grafana/performance_statistics.json"
---
# 6. Query Statistics Dashboard (URL reference)
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: vllm-query-dashboard
  namespace: monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  folder: "vLLM Monitoring"
  url: "https://raw.githubusercontent.com/vllm-project/vllm/main/examples/observability/dashboards/grafana/query_statistics.json"
```

Save as `hybrid-deployment-complete.yaml`, update the `Endpoints` IP, then apply:

```bash
kubectl apply -f hybrid-deployment-complete.yaml
```

Verify:
1. Prometheus targets: `kubectl port-forward svc/prometheus-k8s 9090:9090 -n monitoring`, then open `http://localhost:9090/targets`
2. Grafana dashboards: `kubectl port-forward svc/grafana-service 3000:3000 -n <grafana-namespace>`, then open `http://localhost:3000` → `vLLM Monitoring` folder
