# Deploy vLLM Dashboards with Grafana Operator on Kubernetes

This guide shows how to deploy the vLLM Grafana dashboards using the [Grafana Operator](https://github.com/grafana-operator/grafana-operator) in a Kubernetes cluster.

## Prerequisites

- Grafana Operator installed in your cluster
- A `Grafana` custom resource running (v5+ recommended)
- Prometheus (or Prometheus Operator) running in your cluster
- `kubectl` access to the target namespace

---

## Where Are the vLLM Metrics?

Before configuring dashboards, you need to understand how vLLM exposes metrics and how Prometheus discovers them.

### vLLM Metrics Endpoint

vLLM's OpenAI-compatible server **automatically exposes** Prometheus-format metrics at:

```
http://<vllm-pod-ip>:8000/metrics
```

You can verify this locally with:

```bash
curl http://localhost:8000/metrics | head
```

### In Kubernetes: Service + ServiceMonitor

In a Kubernetes cluster, Prometheus needs to be told **where to scrape** the vLLM metrics. The standard way is:

1. **Expose vLLM with a Kubernetes Service**
2. **Create a `ServiceMonitor`** (if using Prometheus Operator) so Prometheus automatically discovers and scrapes the target

#### Step 1: vLLM Deployment + Service

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-server
  namespace: <your-namespace>
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm-server
  template:
    metadata:
      labels:
        app: vllm-server
    spec:
      containers:
        - name: vllm
          image: vllm/vllm-openai:latest
          ports:
            - name: http
              containerPort: 8000
          args:
            - --model
            - "mistralai/Mistral-7B-v0.1"
            - --max-model-len
            - "2048"
          resources:
            limits:
              nvidia.com/gpu: "1"
---
apiVersion: v1
kind: Service
metadata:
  name: vllm-server
  namespace: <your-namespace>
  labels:
    app: vllm-server
spec:
  selector:
    app: vllm-server
  ports:
    - name: http
      port: 8000
      targetPort: 8000
```

#### Step 2: ServiceMonitor for Prometheus Operator

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: vllm-metrics
  namespace: <your-namespace>
spec:
  selector:
    matchLabels:
      app: vllm-server
  endpoints:
    - port: http
      path: /metrics
      interval: 5s
```

> **Note:** If you are **not** using Prometheus Operator, add a static scrape config to your `prometheus.yml`:
>
> ```yaml
> scrape_configs:
>   - job_name: vllm
>     static_configs:
>       - targets:
>           - vllm-server.<your-namespace>.svc.cluster.local:8000
> ```

### Grafana Data Source

Grafana dashboards need a **Prometheus data source** pointing to your Prometheus instance. If you are using Grafana Operator, you can create it declaratively:

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: prometheus
  namespace: <grafana-namespace>
spec:
  datasource:
    name: prometheus
    type: prometheus
    url: http://prometheus-k8s.monitoring.svc.cluster.local:9090
    access: proxy
    isDefault: true
  instanceSelector:
    matchLabels:
      dashboards: grafana
```

> **What URL should you use?**
>
> | Prometheus Setup | Typical URL |
> |-----------------|-------------|
> | Prometheus Operator (`kube-prometheus-stack`) | `http://prometheus-k8s.monitoring.svc.cluster.local:9090` |
> | Helm `prometheus` chart | `http://prometheus-server.monitoring.svc.cluster.local` |
> | Custom deployment | `http://<prometheus-service>.<namespace>.svc.cluster.local:9090` |
>
> Run `kubectl get svc -n <prometheus-namespace>` to find the exact service name.

---

## Method 1: ConfigMap + configMapRef (Recommended)

The dashboard JSON files are large (~1400 lines). Putting them directly inline in a `GrafanaDashboard` CR is impractical. The recommended approach is to store the JSON in a **ConfigMap** and reference it via `configMapRef`.

### Step 1: Create ConfigMaps for each dashboard

```bash
# Performance Statistics Dashboard
kubectl create configmap vllm-performance-dashboard \
  --from-file=performance_statistics.json \
  -n <your-namespace>

# Query Statistics Dashboard
kubectl create configmap vllm-query-dashboard \
  --from-file=query_statistics.json \
  -n <your-namespace>
```

> **Note:** If you are using GitOps (e.g., ArgoCD, Flux), commit the ConfigMap YAML manifests to your repository instead of using imperative `kubectl create`.

### Step 2: Create GrafanaDashboard CRs

```yaml
# performance-dashboard.yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: vllm-performance-dashboard
  namespace: <your-namespace>
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana  # <-- Must match your Grafana instance labels
  folder: "vLLM Monitoring"
  configMapRef:
    name: vllm-performance-dashboard
    key: performance_statistics.json
```

```yaml
# query-dashboard.yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: vllm-query-dashboard
  namespace: <your-namespace>
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana  # <-- Must match your Grafana instance labels
  folder: "vLLM Monitoring"
  configMapRef:
    name: vllm-query-dashboard
    key: query_statistics.json
```

Apply them:

```bash
kubectl apply -f performance-dashboard.yaml -n <your-namespace>
kubectl apply -f query-dashboard.yaml -n <your-namespace>
```

---

## Method 2: Direct URL Reference

If your cluster has outbound internet access, you can reference the raw JSON directly from GitHub (or any HTTP endpoint):

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: vllm-performance-dashboard
  namespace: <your-namespace>
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  folder: "vLLM Monitoring"
  url: "https://raw.githubusercontent.com/vllm-project/vllm/main/examples/observability/dashboards/grafana/performance_statistics.json"
```

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: vllm-query-dashboard
  namespace: <your-namespace>
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  folder: "vLLM Monitoring"
  url: "https://raw.githubusercontent.com/vllm-project/vllm/main/examples/observability/dashboards/grafana/query_statistics.json"
```

> **Trade-off:** Simple to set up, but depends on external availability and does not work in air-gapped environments.

---

## Important: Matching instanceSelector Labels

The `spec.instanceSelector.matchLabels` must match the labels on your **Grafana** custom resource, not the pod labels. To find the correct labels:

```bash
kubectl get grafana -n <grafana-namespace> -o yaml | grep -A 5 "labels:"
```

Example output:

```yaml
metadata:
  labels:
    app: grafana
    dashboards: grafana
```

In this case, your `instanceSelector` should be:

```yaml
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
```

If no matching labels are found, the dashboard will be created but **will not appear** in any Grafana instance.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Dashboard not showing in Grafana | `instanceSelector` labels do not match `Grafana` CR labels | Check with `kubectl get grafana -o yaml` and align the labels |
| "Failed to load dashboard" | ConfigMap key name mismatch | Ensure `configMapRef.key` exactly matches the file name in the ConfigMap |
| Dashboard empty / no data | Prometheus datasource not configured in Grafana | Add a Prometheus datasource in the Grafana UI or via `GrafanaDatasource` CR |
| Namespace mismatch | GrafanaDashboard and Grafana CR are in different namespaces | Either move them to the same namespace or ensure cross-namespace RBAC |

---

## Complete GitOps Example

Here is a single-file manifest for both dashboards using ConfigMaps (suitable for ArgoCD / Flux):

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: vllm-performance-dashboard
data:
  performance_statistics.json: |
    {
      # ... paste the full content of performance_statistics.json here ...
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: vllm-query-dashboard
data:
  query_statistics.json: |
    {
      # ... paste the full content of query_statistics.json here ...
    }
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: vllm-performance-dashboard
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
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  folder: "vLLM Monitoring"
  configMapRef:
    name: vllm-query-dashboard
    key: query_statistics.json
```

> For production GitOps workflows, consider using tools like [Kustomize](https://kustomize.io/) or [Jsonnet](https://jsonnet.org/) to manage the large JSON payloads instead of inlining them directly.
