# Jenkins on Kubernetes: Docker CLI in agent pods

The default Helm chart pod template only runs `jenkins/inbound-agent`. Pipeline steps that call `docker` fail with `docker: not found` because the client binary and daemon are not present.

## Option A — Docker-in-Docker sidecar (quick)

Merge the snippet in `jcasc-docker-dind-overlay.yaml` into the `jenkins-jenkins-jcasc-config` ConfigMap key `jcasc-default-config.yaml` under `jenkins.clouds[0].kubernetes.templates[0].containers`:

1. Add `DOCKER_HOST` to the **jnlp** container `envVars` (see overlay file).
2. Add a second container **docker** using `docker:dind` with `privileged: true` and `DOCKER_TLS_CERTDIR=""`.

Then reload Configuration as Code or restart the Jenkins controller pod.

**Note:** Privileged pods are required for standard `docker:dind`. Your Kyverno policies should exclude the `jenkins` namespace for this to schedule (already typical for infra namespaces).

## Option B — Kaniko / Tekton (preferred for production)

Build images with `gcr.io/kaniko-project/executor` (see `../tekton/node-build-pipeline.yaml`) instead of Docker on the Jenkins agent.

## Option C — Docker socket mount (not recommended)

Bind-mount the host Docker socket; weaker isolation.

## What was applied in this repo

- `jcasc-configmap.fetched.yaml` — live export with **docker-cli** + **dind** containers added to the default pod template (apply to `jenkins-jenkins-jcasc-config` in namespace `jenkins`).
- `pipeline-job-config.xml` — `pipeline` job uses `agent { label 'jenkins-jenkins-agent' }` and wraps Docker steps in `container('docker')`.
- `post_pipeline_config_local.py` — posts `config.xml` to Jenkins NodePort with crumb + cookies (avoids HTTP 403 from in-pod `curl`).

**GitOps token:** `GITOPS_REPO_TOKEN` must return GitHub API `200` for `GET /repos/<owner>/<repo>` with `permissions.push: true`. Replace revoked/invalid tokens.
