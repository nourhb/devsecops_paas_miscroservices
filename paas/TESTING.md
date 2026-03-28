# DevSecOps PaaS – End-to-End Testing Guide

This guide describes how to **test your PaaS platform end-to-end**: from code push → CI/CD pipeline → container build → security scans → GitOps deployment → monitoring. Use it to validate the platform and to demonstrate it during a PFE defense.

---

## Prerequisites

Before testing, ensure:

- **Kubernetes cluster** is up (e.g. kubeadm with 1 master + 2 workers).
- **Infrastructure is running**: Jenkins (Helm), Harbor, ArgoCD, Prometheus/Grafana (kube-prometheus-stack), OPA Gatekeeper, SonarQube, Trivy (in Jenkins or cluster).
- **PaaS backend & frontend** are running (see [README.md](./README.md)) with correct `.env` / environment variables.
- You have **one project** created in the PaaS UI with a linked Git repo and a Jenkins pipeline job (`project-<projectId>`).

---

## 1. Test the Application Build (CI)

Verify that the **CI pipeline runs** when you push code or trigger a build from the PaaS.

### Option A: Trigger from PaaS UI

1. Open the PaaS dashboard (e.g. `http://localhost:3000`).
2. Go to **Projects** → select your project → **Build** or **Deploy** (one-click deploy).
3. Or call the API:

   ```bash
   curl -X POST http://localhost:4000/api/deploy \
     -H "Content-Type: application/json" \
     -d '{"projectId":"<your-project-id>","branch":"main","commitSha":"HEAD"}'
   ```

### Option B: Push from application repo

1. Go to your **application repository** (the one linked to the project in the PaaS).
2. Make a small change (e.g. edit README or add a log line).
3. Commit and push:

   ```bash
   git add .
   git commit -m "test pipeline"
   git push
   ```

### Expected result

- In **Jenkins** you should see a pipeline start (either by webhook or by the job you created via PaaS).
- Pipeline stages (from `paas/jenkins/Jenkinsfile.template`) should run in order:
  - **Checkout**
  - **Build & Test** (`npm ci`, `npm test`)
  - **Trivy Scan** (filesystem)
  - **SonarQube Analysis**
  - **Docker Build**
  - **Trivy Image Scan** (container image; fails on HIGH/CRITICAL)
  - **Cosign Sign**
  - **Push to Harbor**
  - **Update GitOps Repo**

If the pipeline runs successfully through these stages → **CI is working**.

---

## 2. Test Security Scanning

### SonarQube

- **Check**: Code quality analysis runs in the pipeline; Quality Gate is evaluated.
- **Expected**: If the Quality Gate **fails**, the pipeline should stop (configure `waitForQualityGate()` in Jenkins if needed).
- **Where to look**: SonarQube UI → your project → Quality Gate status and issues.

### Trivy

- **Filesystem scan**: Runs in CI on source (e.g. `trivy fs --severity HIGH,CRITICAL`).
- **Image scan**: Runs on the built Docker image before push; typically `--exit-code 1` for HIGH/CRITICAL so the pipeline fails on critical vulnerabilities.
- **Expected**: If **CRITICAL** (or configured HIGH) vulnerabilities exist, the pipeline fails → **DevSecOps enforcement** is working.
- **PaaS**: Scan results can be stored in the database via `trivy.ts` and shown under **Security** in the dashboard.

---

## 3. Test Container Registry (Harbor)

After a successful pipeline run:

1. Open **Harbor** (URL from `HARBOR_URL`).
2. Navigate to the project and repository that match your app (e.g. from `registryRepo` in the PaaS project).
3. Verify:
   - A **new image** is present.
   - **Tag** is updated (e.g. commit SHA or `latest`).
   - If Cosign is configured, the image is **signed** (Harbor may show signature or you can verify with `cosign verify`).

---

## 4. Test GitOps Deployment (CD)

### Steps

1. **Check the GitOps repository** (the one ArgoCD watches, e.g. from `GITOPS_REPO_URL`).
2. After the Jenkins “Update GitOps Repo” stage, the Helm **values** (or kustomize overlay) should be updated with the new image tag, for example:

   ```yaml
   image:
     repository: harbor.example.com/myproject/myapp
     tag: abc1234
   ```

3. **ArgoCD** detects the change and syncs.

### Expected result

- ArgoCD Application (e.g. `project-<projectId>`) shows **Synced** and **Healthy**.
- New pods are deployed with the updated image:

  ```bash
  kubectl get pods -n <app-namespace>
  kubectl describe pod <pod-name> -n <app-namespace>   # check image tag
  ```

If the new pod is running with the new tag → **CD is working**.

---

## 5. Test Runtime Security (OPA Gatekeeper)

Verify that the cluster **blocks unsigned or non-compliant images**.

### Test: Deploy an unsigned image

1. Create a minimal Deployment manifest that uses an **unsigned** image (or one without the required `cosign.sig` annotation, depending on your OPA constraint).
2. Try to apply it:

   ```bash
   kubectl apply -f unsigned-deployment.yaml
   ```

### Expected result

- The **admission controller** (OPA Gatekeeper) **rejects** the deployment with a message indicating that the image must be signed or that the required annotation is missing.
- This confirms **runtime security policies** are enforced.

Your constraint lives under `paas/k8s/opa/` (e.g. `cosign-signed-images-constraint.yaml`). Ensure the constraint and ConstraintTemplate are applied to the cluster.

---

## 6. Test Monitoring

### Prometheus

- **Metrics**: Ensure Prometheus is scraping the cluster and your app (if metrics are exposed).
  ```bash
  # If Prometheus is exposed (e.g. port-forward):
  kubectl port-forward svc/prometheus-kube-prometheus-stack-prometheus -n monitoring 9090:9090
  # Then open http://localhost:9090 and run a query, e.g. up
  ```
- **PaaS**: The dashboard uses `GET /api/metrics`, which aggregates Prometheus data (node count, CPU, memory) when `PROMETHEUS_URL` is set.

### Grafana

- Open **Grafana** (URL from `GRAFANA_URL` or `NEXT_PUBLIC_GRAFANA_URL`).
- Check dashboards for:
  - **Pod CPU / memory usage**
  - **Application metrics** (if your app exposes them and they are scraped).
- The PaaS **Monitoring** page can embed a Grafana dashboard URL for the project.

---

## 7. Test Failure Scenarios

A robust platform should **fail fast** on security or quality issues.

| Case | Action | Expected result |
|------|--------|-----------------|
| **Vulnerable dependency** | Add a known vulnerable library to the app and run the pipeline. | **Trivy** (or dependency check) fails the pipeline. |
| **Code quality failure** | Introduce bad code (e.g. security hotspot, bug) that fails the Sonar Quality Gate. | **SonarQube** fails the pipeline. |
| **Bad deployment** | Break the Helm chart (e.g. invalid value, wrong image pull secret). | **ArgoCD** reports sync failure / degraded; pod may not start. |
| **Unsigned image** | Try to deploy a pod with an unsigned image (see §5). | **OPA Gatekeeper** blocks the admission. |

---

## 8. Final End-to-End Test

Run one full cycle and confirm each step:

1. **Developer** pushes code (or triggers deploy from PaaS).
2. **Jenkins** pipeline starts (Build → Test → Trivy → Sonar → Docker build → Trivy image → Cosign → Push to Harbor → Update GitOps).
3. **Security scans** run (SonarQube + Trivy); pipeline fails if policy is violated.
4. **Docker image** is built and pushed to **Harbor**.
5. **GitOps repo** is updated with the new image tag.
6. **ArgoCD** syncs and deploys the new version to Kubernetes.
7. **Prometheus** collects metrics from the cluster (and app if configured).
8. **Grafana** displays monitoring for the workload.

If all steps succeed → **your PaaS works correctly** end-to-end.

---

## Summary Checklist

| Layer | What to test | How |
|-------|----------------|-----|
| **CI** | Jenkins pipeline execution | Push code or trigger via PaaS; check Jenkins job and stages. |
| **Security** | SonarQube + Trivy | Run pipeline; confirm quality gate and vulnerability checks pass/fail as expected. |
| **Registry** | Image in Harbor | After pipeline, check Harbor for new image and tag; optional Cosign signature. |
| **CD** | ArgoCD deployment | Confirm GitOps repo updated; ArgoCD syncs; new pods with correct image. |
| **Runtime** | OPA policies | Try to deploy unsigned image; admission must block. |
| **Observability** | Prometheus + Grafana | Check metrics and dashboards for cluster and app. |

---

## Quick Health Check (PaaS API)

Before deep testing, ensure the PaaS can talk to all services:

```bash
BASE=http://localhost:4000
curl -s $BASE/api/health | jq .
curl -s $BASE/api/test/jenkins | jq .
curl -s $BASE/api/test/harbor | jq .
curl -s $BASE/api/test/argocd | jq .
curl -s $BASE/api/test/kubernetes | jq .
```

All should return `"ok": true` when credentials and endpoints are correctly set in `.env`.

---

## 5 Demo Tests for PFE Defense

Typical evaluation scenarios for a DevSecOps platform:

1. **Create project & trigger pipeline** – In the PaaS UI, create a project (or use existing), link repo, trigger deploy; show Jenkins pipeline running and completing.
2. **Show security in the pipeline** – Open SonarQube and Trivy results; show that a failed quality gate or critical CVE fails the build.
3. **Show GitOps deployment** – Show ArgoCD UI with the application synced; show `kubectl get pods` with the new image tag after a pipeline run.
4. **Show policy enforcement** – Apply a manifest with an unsigned image and show that Gatekeeper denies it.
5. **Show monitoring** – Open Grafana dashboard with CPU/memory (and app metrics if available) for the deployed workload.

Use this document and the checklist above to prepare and document your testing for the defense.
