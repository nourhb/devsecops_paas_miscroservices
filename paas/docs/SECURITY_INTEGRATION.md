# Security Integration Points

## Overview

Security is integrated at multiple stages: **code**, **dependencies**, **container**, **deployment**, and **runtime**.

## 1. Static Application Security Testing (SAST) – SonarQube

- **When:** After build, in Jenkins.
- **How:** SonarScanner runs against source; results sent to SonarQube; quality gate can fail the pipeline.
- **PaaS:** Pipeline is triggered by PaaS; developer sees pass/fail in UI, not in SonarQube directly (black box).

## 2. Software Composition Analysis (SCA) – Dependency-Check / Dependency-Track

- **When:** After dependency resolution; report (or SBOM) generated and optionally sent to Dependency-Track.
- **How:** Jenkins runs OWASP Dependency-Check (or similar); optionally uploads CycloneDX/SPDX to Dependency-Track; policy can fail build on critical CVEs.
- **PaaS:** Results can be summarized in PaaS UI (e.g. “Dependencies: X critical, Y high”).

## 3. Container scanning – Trivy

- **When:** After Docker build, before push to Harbor.
- **How:** `trivy image` in Jenkins; exit code 1 on CRITICAL/HIGH (configurable); report stored or sent to security dashboard.
- **PaaS:** Pipeline status reflects Trivy result; optional link to report.

## 4. Image signing – Cosign

- **When:** After push to Harbor.
- **How:** Jenkins runs `cosign sign` with key from secrets; signature stored (Harbor OCI artifact or registry).
- **Runtime:** OPA Gatekeeper can enforce “only signed images” so that unsigned images are rejected at deploy time.

## 5. Runtime policy – OPA Gatekeeper

- **When:** At Kubernetes admission (create/update of Pods, Deployments, etc.).
- **How:** ConstraintTemplates define policies (e.g. “image must have Cosign annotation”, “no latest tag”); Constraints bind them to resources.
- **PaaS:** Developers cannot deploy non-compliant workloads; platform remains secure without exposing Gatekeeper to users.

## 6. Dynamic Application Security Testing (DAST) – OWASP ZAP

- **When:** After deployment, when the app is reachable (staging URL).
- **How:** Jenkins (or separate job) runs ZAP against the deployed URL; report generated; optional fail on high/critical findings.
- **PaaS:** “Security” tab can show DAST status or link to report.

## Summary table

| Phase     | Tool              | Integration point              |
|----------|-------------------|---------------------------------|
| Code     | SonarQube         | Jenkins pipeline, quality gate |
| Deps     | Dependency-Track  | Jenkins, SBOM upload           |
| Container| Trivy             | Jenkins, before push           |
| Sign     | Cosign            | Jenkins, after push            |
| Deploy   | OPA Gatekeeper    | K8s admission                  |
| Runtime  | OWASP ZAP         | Jenkins post-deploy job        |
