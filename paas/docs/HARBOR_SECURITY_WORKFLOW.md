# Harbor, Trivy, and Cosign – Image Security Workflow

## Harbor architecture

- **Harbor** runs as a private Docker registry (and optionally OCI) with projects, RBAC, replication, and retention.
- **ChartMuseum** can run alongside Harbor (same or separate deployment) to store Helm charts; Jenkins pushes charts after packaging.
- **Workflow:** Build image → Trivy scan (in Jenkins) → Push to Harbor → Cosign sign (signature as OCI artifact or separate store).

## Image push and security workflow

1. **Build:** `docker build -t <harbor-host>/<project>/<repo>:<tag> .`
2. **Scan:** `trivy image --exit-code 1 --severity CRITICAL,HIGH <image>`
3. **Push:** `docker push <image>`
4. **Sign:** `cosign sign --key cosign.key <image>`
5. **Verify (in pipeline or cluster):** `cosign verify --key cosign.pub <image>`

## Example commands

```bash
# Login
docker login harbor.example.com -u robot\$paas-ci -p <token>

# Tag and push
export HARBOR=harbor.example.com
export PROJECT=paas
export APP=my-app
export TAG=1.2.3
docker tag my-app:latest $HARBOR/$PROJECT/$APP:$TAG
docker push $HARBOR/$PROJECT/$APP:$TAG

# Trivy scan (before or after push)
trivy image --exit-code 0 --severity HIGH,CRITICAL --ignore-unfixed $HARBOR/$PROJECT/$APP:$TAG

# Cosign sign (key from secret)
cosign sign --key cosign.key $HARBOR/$PROJECT/$APP:$TAG

# Cosign verify
cosign verify --key cosign.pub $HARBOR/$PROJECT/$APP:$TAG
```

## ChartMuseum (Helm)

```bash
# Add ChartMuseum repo and push chart
helm repo add chartmuseum https://chartmuseum.example.com
helm push my-app-1.2.3.tgz chartmuseum
```

## Security workflow summary

| Step   | Tool   | Purpose                    |
|--------|--------|----------------------------|
| Scan   | Trivy  | CVE/vulnerability check    |
| Sign   | Cosign | Image signing              |
| Verify | Cosign / OPA | Enforce signed images in K8s |
