# PFE DevSecOps – Step-by-Step Guide

Complete pipeline from containerization to monitoring on your Kubernetes cluster (kubeadm, 1 master + 2 workers, Calico, Ubuntu).

---

## Prerequisites (already done)

- Kubernetes cluster (kubeadm), 1 master + 2 workers, all Ready  
- Calico, Docker, Ubuntu  
- Next.js app running locally  
- Docker Hub account  

---

## 1. Containerization

### 1.1 Production Dockerfile (already in `backend-next/`)

The Next.js app uses a multi-stage Dockerfile and `output: "standalone"` in `next.config.mjs`.

### 1.2 Build the image

```bash
cd paas/backend-next
docker build -t next-app:latest .
```

### 1.3 Test the container locally

```bash
docker run -p 4000:4000 next-app:latest
# In another terminal:
curl http://localhost:4000/api/health
# Stop: Ctrl+C
```

**Verification:** You get a JSON response from `/api/health`.

---

## 2. Container registry (Docker Hub)

### 2.1 Login and tag

```bash
docker login
# Enter your Docker Hub username and password (or token)

# Replace YOUR_DOCKERHUB_USER with your Docker Hub username
export DOCKERHUB_USER=YOUR_DOCKERHUB_USER
docker tag next-app:latest $DOCKERHUB_USER/next-app:latest
```

### 2.2 Push to Docker Hub

```bash
docker push $DOCKERHUB_USER/next-app:latest
```

**Verification:** Image appears at `https://hub.docker.com/r/YOUR_DOCKERHUB_USER/next-app`.

---

## 3. Kubernetes deployment

### 3.1 Set your image in the Deployment

Edit `paas/k8s-next-app/deployment.yaml` and replace `<DOCKERHUB_USERNAME>` with your Docker Hub username:

```yaml
image: YOUR_DOCKERHUB_USER/next-app:latest
```

### 3.2 Deploy

```bash
kubectl apply -f paas/k8s-next-app/deployment.yaml
kubectl apply -f paas/k8s-next-app/service.yaml
```

### 3.3 Verify pods and service

```bash
kubectl get pods -l app=next-app
kubectl get svc next-app
```

**Verification:** Pod is `Running`, Service type is `NodePort` and has a port (e.g. `30080`).

### 3.4 Access via NodePort

```bash
# Get a worker node IP
kubectl get nodes -o wide
# Open in browser or curl (use one of the EXTERNAL-IPs and port 30080):
curl http://<NODE_IP>:30080/api/health
```

---

## 4. Application exposure (NGINX Ingress)

### 4.1 Install NGINX Ingress Controller

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/baremetal/deploy.yaml
# Wait for the controller to be ready:
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

### 4.2 (Optional) Patch for NodePort

If you don’t have a load balancer, use NodePort for the Ingress controller:

```bash
kubectl patch svc ingress-nginx-controller -n ingress-nginx -p '{"spec":{"type":"NodePort"}}'
kubectl get svc -n ingress-nginx
# Note the NodePort for port 80 (e.g. 30000–32767).
```

### 4.3 Add host to /etc/hosts and apply Ingress

On your laptop (or wherever you browse):

```bash
# Add (replace NODE_IP with one of your worker IPs):
echo "NODE_IP next-app.local" | sudo tee -a /etc/hosts
```

On the cluster:

```bash
kubectl apply -f paas/k8s-next-app/ingress.yaml
```

### 4.4 Access via Ingress

- If you use the NodePort for port 80: `http://next-app.local:<NODEPORT>`
- Or `http://next-app.local` if you pointed DNS / LB to the Ingress NodePort.

**Verification:** Same JSON as before from `/api/health`.

---

## 5. CI/CD pipeline (Jenkins)

### 5.1 Install Jenkins in Kubernetes (Helm)

```bash
helm repo add jenkinsci https://charts.jenkins.io
helm repo update
kubectl create namespace jenkins
helm install jenkins jenkinsci/jenkins -n jenkins --set controller.installPlugins={workflow-aggregator:latest,git:latest,configuration-as-code:latest}
# Get admin password:
kubectl exec -n jenkins svc/jenkins -c jenkins -- cat /var/jenkins_home/secrets/initialAdminPassword
# Port-forward to access UI:
kubectl port-forward -n jenkins svc/jenkins 8080:8080
# Open http://localhost:8080, complete setup, install suggested plugins.
```

### 5.2 Configure credentials in Jenkins

1. **Jenkins → Manage Jenkins → Credentials → Add:**
   - **Docker Hub:** Username + Password (or token).
   - **Kubernetes:** If Jenkins runs outside the cluster, add a kubeconfig or “Kubernetes configuration” so the pipeline can run `kubectl`.

2. **Manage Jenkins → Configure System:** Add env vars or use “Environment variables” for the pipeline:
   - `DOCKERHUB_USERNAME`
   - `DOCKERHUB_TOKEN` (or `DOCKERHUB_PASSWORD`)

3. Ensure the Jenkins agent (or master) has `kubectl` and access to the cluster (e.g. copy kubeconfig to the Jenkins pod or use in-cluster service account).

### 5.3 Create pipeline job

1. New Item → Pipeline.
2. Pipeline definition: “Pipeline script from SCM”.
3. SCM: Git, repo URL (your GitHub repo that contains `backend-next/` and the Jenkinsfile).
4. Script Path: `paas/backend-next/Jenkinsfile` (or `backend-next/Jenkinsfile` if repo root is different).
5. Save and “Build Now”.

**Pipeline steps:** Checkout → Trivy scan → Push to Docker Hub → Deploy to Kubernetes (`kubectl set image` + `rollout status`).

**Verification:** Build succeeds; new image is on Docker Hub; `kubectl get pods -l app=next-app` shows a new pod with the new image tag.

---

## 6. Monitoring (Prometheus + Grafana)

### 6.1 Install Prometheus (Helm)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
kubectl create namespace monitoring
helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false
```

### 6.2 Install Grafana (included in kube-prometheus-stack)

Grafana is part of the same chart. Get the admin password and port-forward:

```bash
kubectl get secret -n monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 --decode
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Open http://localhost:3000, login (admin / password from above).
```

### 6.3 Verify

- Prometheus: `kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090` → http://localhost:9090.
- Grafana: already has a Prometheus datasource; you can import Kubernetes dashboards (e.g. “Kubernetes cluster” or “Node Exporter”).

---

## 7. Security (Trivy in pipeline)

Trivy is already in the Jenkinsfile:

```groovy
stage('Trivy Scan') {
  steps {
    sh "docker build -t ${IMAGE_FULL} ."
    sh "trivy image --exit-code 0 --severity HIGH,CRITICAL --ignore-unfixed ${IMAGE_FULL} || true"
  }
}
```

- Install Trivy on the Jenkins agent (or use a Trivy Docker image in the pipeline).
- To **fail** the build on HIGH/CRITICAL, change to `--exit-code 1` and remove `|| true`.

**Verification:** In a build, open “Console Output” and confirm Trivy runs and prints scan results.

---

## Quick reference

| Step              | Main commands / files |
|------------------|------------------------|
| Build image      | `docker build -t next-app:latest .` in `paas/backend-next` |
| Push             | `docker tag` + `docker push $DOCKERHUB_USER/next-app:latest` |
| Deploy once      | `kubectl apply -f paas/k8s-next-app/deployment.yaml` + `service.yaml` |
| Ingress          | Install NGINX Ingress, then `kubectl apply -f paas/k8s-next-app/ingress.yaml` |
| Jenkins          | Helm install Jenkins, add Docker Hub + kubeconfig, create Pipeline from SCM + `Jenkinsfile` |
| Monitoring       | `helm install ... kube-prometheus-stack` in `monitoring` namespace |
| Trivy            | Already in `paas/backend-next/Jenkinsfile` |

---

## Verification checklist

- [ ] `docker run` and `curl http://localhost:4000/api/health` work.
- [ ] Image is on Docker Hub.
- [ ] `kubectl get pods` and `kubectl get svc` show `next-app` Running and NodePort.
- [ ] App is reachable via NodePort and (optionally) Ingress.
- [ ] Jenkins pipeline runs and updates the deployment.
- [ ] Prometheus and Grafana are up; Grafana can query Prometheus.
- [ ] Trivy runs in the pipeline and shows scan output.
