# Cluster Monitoring – Prometheus and Grafana

## Monitoring architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │ Application │  │ Node        │  │ Ingress / Services      │  │
│  │ Pods        │  │ metrics     │  │                         │  │
│  └──────┬──────┘  └──────┬──────┘  └────────────┬────────────┘  │
│         │                │                       │               │
│         └────────────────┼───────────────────────┘               │
│                          ▼                                        │
│                 ┌─────────────────┐                               │
│                 │ Prometheus      │  Scrape /metrics, node-exporter│
│                 │ (in cluster)    │                               │
│                 └────────┬────────┘                               │
└──────────────────────────┼────────────────────────────────────────┘
                           │
                           ▼
                  ┌─────────────────┐
                  │ Grafana         │  Dashboards, alerts
                  │ Datasource:     │  Per-project views
                  │ Prometheus      │
                  └─────────────────┘
```

## Components

- **Prometheus:** Scrapes metrics from Kubernetes (cAdvisor, kube-state-metrics, node-exporter) and from application endpoints (e.g. `/metrics`).
- **Grafana:** Uses Prometheus as a datasource; dashboards for cluster health, node/pod CPU/memory, and per-application metrics.
- **Placement:** Both run inside the cluster (e.g. `monitoring` namespace), installed via Helm (`kube-prometheus-stack`) or Terraform/Helm.

## Example dashboards

| Dashboard        | Purpose                                   |
|------------------|-------------------------------------------|
| Cluster overview | Nodes, namespaces, pod count, resource usage |
| Node metrics     | CPU, memory, disk per node                |
| Workload (per app) | Deployment replicas, restarts, requests per app |
| PaaS control plane | API latency, error rate for PaaS API     |

## Per-project dashboards

- One Grafana folder per project (or tag by `namespace` / `app`).
- Prometheus queries filter by `namespace`, `pod`, or `deployment` labels.
- PaaS UI can link to a pre-filtered Grafana dashboard URL (e.g. `?var-namespace=my-app`).

## Alerting

- Prometheus Alertmanager sends alerts (e.g. PodCrashLooping, HighMemory).
- Rules stored in `monitoring/prometheus/rules/` or as ConfigMap; Grafana can also define alerts.
