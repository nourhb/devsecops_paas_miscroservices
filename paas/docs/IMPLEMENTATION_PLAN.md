# DevSecOps PaaS – Implementation Plan

## Phase 1 – Foundation (Weeks 1–2)

1. **Infrastructure (Terraform)**  
   - Provision VPC, subnets, and Kubernetes cluster (EKS/AKS/GKE or kubeadm on VMs).  
   - Document and apply from `terraform/environments/dev`.

2. **Kubernetes baseline**  
   - Install Ingress controller (NGINX); configure TLS (cert-manager or cloud LB).  
   - Apply base namespaces and RBAC.  
   - Apply OPA Gatekeeper (constraint templates + constraints from `k8s-manifests/gatekeeper/`).

3. **Harbor + ChartMuseum**  
   - Deploy Harbor (and ChartMuseum if used).  
   - Create projects and robot accounts for CI.  
   - Configure Trivy and Cosign (key generation, store keys in Jenkins/K8s secrets).

## Phase 2 – CI/CD core (Weeks 3–4)

4. **Jenkins**  
   - Deploy Jenkins in Kubernetes (Helm).  
   - Configure credentials (Harbor, Git, Artifactory, Cosign, SonarQube, ArgoCD).  
   - Create pipeline job(s) from `jenkins/Jenkinsfile.pipeline`; parameterize app name, repo, branch.

5. **PaaS control plane**  
   - Deploy `backend-next` (Next.js API + UI).  
   - Implement: project CRUD, “Trigger build”, “Trigger deploy”, status from Jenkins/ArgoCD.  
   - Expose PaaS via Ingress (HTTPS).

6. **Git integration**  
   - Configure webhooks (GitLab/GitHub) to PaaS API.  
   - PaaS maps webhook payload to project and triggers Jenkins job.  
   - Test: push to Git → build starts without opening Jenkins.

## Phase 3 – GitOps and deployment (Week 5)

7. **GitOps repo**  
   - Create Git repo for GitOps (e.g. `gitops-repo`); structure `apps/<app>/` with Chart and values.  
   - Jenkins has write access; updates `values.yaml` (image tag) and pushes.

8. **ArgoCD**  
   - Install ArgoCD in cluster.  
   - Create Application per app (or app-of-apps) pointing at GitOps repo.  
   - Enable auto-sync; verify deploy after Jenkins pushes.

## Phase 4 – Security and quality (Weeks 6–7)

9. **SonarQube**  
   - Deploy SonarQube; configure quality gate.  
   - Add SonarScanner step to Jenkinsfile; fail pipeline on quality gate failure.

10. **Dependency-Track / Dependency-Check**  
    - Deploy Dependency-Track (or use SaaS).  
    - In Jenkins: generate SBOM (e.g. CycloneDX), upload to Dependency-Track; optionally fail on policy.

11. **OWASP ZAP**  
    - Add post-deploy stage in Jenkins: run ZAP against staging URL; archive report.  
    - Optionally fail on high/critical.

## Phase 5 – Monitoring and hardening (Week 8)

12. **Prometheus + Grafana**  
    - Install kube-prometheus-stack (or equivalent).  
    - Create dashboards: cluster, nodes, per-app; link from PaaS UI.

13. **Artifactory**  
    - Deploy or connect to Artifactory.  
    - Add publish step in Jenkins; optionally add “Artifact” link in PaaS.

14. **Documentation and handover**  
    - Finalize docs in `docs/`; runbooks for failures; handover to ops.

---

## Success criteria

- Developer can create a project in PaaS, link Git repo, push code, and see build + deploy without using Jenkins UI.  
- All applications are exposed via Ingress with HTTPS.  
- Images are scanned (Trivy), signed (Cosign), and policies enforced (Gatekeeper).  
- SAST (SonarQube), SCA (Dependency-Track), and DAST (ZAP) are integrated and visible or reportable from PaaS.
