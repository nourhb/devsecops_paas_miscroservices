import { env } from "@/server/config/env";
import { isPlaceholderValue, realValueOrEmpty } from "@/server/config/real-values";
import { argocdIntegrationFetch } from "@/server/http/argocd-fetch";
import { probeHostIsRemapSource } from "@/server/http/integration-probe-host";
import { integrationFetch } from "@/server/http/integration-fetch";
import { getCoreV1Api } from "@/server/integrations/kubernetes-client";
import type { PlatformIntegrationItem, PlatformIntegrationReachability, PlatformIntegrationsResponse } from "@/types";
const CONCURRENCY = 12;
function joinUrl(base: string, suffix: string): string {
    const b = base.replace(/\/+$/, "");
    const s = suffix.startsWith("/") ? suffix : `/${suffix}`;
    return `${b}${s}`;
}
function jenkinsAuthHeader(): string {
    return `Basic ${Buffer.from(`${env.JENKINS_USERNAME}:${env.JENKINS_API_TOKEN}`).toString("base64")}`;
}
function harborAuthHeader(): string | null {
    const u = env.HARBOR_USERNAME?.trim();
    const p = env.HARBOR_PASSWORD?.trim();
    if (!u || !p) {
        return null;
    }
    return `Basic ${Buffer.from(`${u}:${p}`).toString("base64")}`;
}
type HttpProbeCtx = {
    itemId?: string;
    bypassHostRemap?: boolean;
    timeoutMs?: number;
};
function labNodeBase(): string {
    const ip = env.APPS_PUBLIC_LAB_NODE_IP.trim();
    return ip ? `http://${ip}` : "";
}
async function hasRunningPodMatching(namespace: string, namePattern: RegExp): Promise<boolean> {
    const api = getCoreV1Api();
    if (!api) {
        return false;
    }
    try {
        const { body } = await api.listNamespacedPod(namespace);
        const items = body.items ?? [];
        return items.some((pod) => namePattern.test(pod.metadata?.name ?? "") && pod.status?.phase === "Running");
    }
    catch {
        return false;
    }
}
async function probeMany(bases: string[], path: string, ctx: HttpProbeCtx): Promise<PlatformIntegrationReachability> {
    const seen = new Set<string>();
    for (const raw of bases) {
        const base = raw.replace(/\/+$/, "");
        if (!base || seen.has(base)) {
            continue;
        }
        seen.add(base);
        const r = await httpProbe(joinUrl(base, path), {}, ctx);
        if (r.state === "reachable") {
            return r;
        }
    }
    const first = bases.find(Boolean) ?? "";
    return {
        state: "unreachable",
        latencyMs: 0,
        message: "Not reachable"
    };
}
async function httpProbe(url: string, init: RequestInit = {}, ctx?: HttpProbeCtx): Promise<PlatformIntegrationReachability> {
    const t0 = Date.now();
    const timeoutMs = ctx?.timeoutMs ?? env.PLATFORM_INTEGRATION_PROBE_TIMEOUT_MS;
    try {
        const res = await integrationFetch(url, {
            method: "GET",
            redirect: "follow",
            ...init
        }, {
            timeoutMs,
            bypassHostRemap: Boolean(ctx?.bypassHostRemap)
        });
        const ms = Date.now() - t0;
        if (res.ok || res.status === 301 || res.status === 302 || res.status === 401 || res.status === 403) {
            return {
                state: "reachable",
                latencyMs: ms,
                message: res.ok ? undefined : `HTTP ${res.status}`
            };
        }
        const raw = typeof res.status === "number" && res.status > 0 ? `HTTP ${res.status}` : "Empty response";
        return {
            state: "unreachable",
            latencyMs: ms,
            message: raw
        };
    }
    catch (error) {
        const ms = Date.now() - t0;
        const message = integrationProbeErrorMessage(error);
        return {
            state: "unreachable",
            latencyMs: ms,
            message: message
        };
    }
}
function integrationProbeErrorMessage(error: unknown): string {
    if (!(error instanceof Error)) {
        return String(error);
    }
    const c = error.cause;
    if (c instanceof Error && c.message && !error.message.includes(c.message)) {
        return `${error.message} (${c.message})`;
    }
    return error.message;
}
async function probeByItemId(item: PlatformIntegrationItem): Promise<PlatformIntegrationReachability> {
    if (item.kind === "external" && item.href && isPlaceholderValue(item.href)) {
        return {
            state: "skipped",
            message: "Placeholder URL is not accepted"
        };
    }
    if (item.kind === "cli") {
        if (item.id === "cosign") {
            const hasKeys = Boolean(realValueOrEmpty(env.COSIGN_PUBLIC_KEY) || realValueOrEmpty(env.COSIGN_PRIVATE_KEY));
            const labPolicy = process.env.COSIGN_LAB_POLICY === "true" || env.COSIGN_ENFORCE_SIGNED === "true";
            if (hasKeys || labPolicy) {
                return {
                    state: "reachable",
                    latencyMs: 0,
                    message: hasKeys ? "Cosign keys configured" : "Image signing policy enabled (COSIGN_ENFORCE_SIGNED)"
                };
            }
        }
        return {
            state: "skipped",
            message: item.configured ? "Configured (no HTTP endpoint)" : "Not configured"
        };
    }
    if (item.kind === "internal") {
        if (item.id === "cluster-paas-ui") {
            const t0 = Date.now();
            const api = getCoreV1Api();
            if (!api) {
                return {
                    state: "skipped",
                    message: "Kubernetes API not available"
                };
            }
            try {
                await api.listNode();
                return {
                    state: "reachable",
                    latencyMs: Date.now() - t0,
                    message: "API reachable"
                };
            }
            catch (error) {
                return {
                    state: "unreachable",
                    latencyMs: Date.now() - t0,
                    message: error instanceof Error ? error.message : String(error)
                };
            }
        }
        if (item.id === "artifacts-spring") {
            const base = (process.env.SPRING_BACKEND_BASE_URL || "").trim().replace(/\/+$/, "");
            if (!base) {
                return {
                    state: "skipped",
                    message: "SPRING_BACKEND_BASE_URL not set"
                };
            }
            return httpProbe(joinUrl(base, "/artifacts"), {}, { itemId: item.id });
        }
        if (item.id === "project-security") {
            return {
                state: "reachable",
                message: "In-app"
            };
        }
        return {
            state: "skipped",
            message: "In-app"
        };
    }
    if (!item.href) {
        if (item.id === "kyverno" && env.POLICY_ENGINE === "kyverno") {
            return {
                state: "reachable",
                latencyMs: 0,
                message: "POLICY_ENGINE=kyverno — admission policies in-cluster (optional NEXT_PUBLIC_KYVERNO_UI_URL)."
            };
        }
        if (item.id === "opa-gatekeeper" && env.POLICY_ENGINE === "gatekeeper") {
            return {
                state: "reachable",
                latencyMs: 0,
                message: "POLICY_ENGINE=gatekeeper — Gatekeeper admission (optional dashboard URL)."
            };
        }
        if (item.id === "cert-manager" && process.env.CERT_MANAGER_INSTALLED === "true") {
            if (await hasRunningPodMatching("cert-manager", /cert-manager/)) {
                return {
                    state: "reachable",
                    latencyMs: 0,
                    message: "cert-manager running in-cluster"
                };
            }
        }
        if (item.id === "kubewarden" && process.env.KUBEWARDEN_INSTALLED === "true") {
            if (await hasRunningPodMatching("kubewarden", /policy-server|kubewarden|audit-scanner/)) {
                return {
                    state: "reachable",
                    latencyMs: 0,
                    message: "Kubewarden policy server running in-cluster"
                };
            }
        }
        if (item.id === "calico" && process.env.CALICO_INSTALLED === "true") {
            return {
                state: "reachable",
                latencyMs: 0,
                message: "Calico CNI detected in cluster"
            };
        }
        if (item.id === "tekton" && process.env.TEKTON_INSTALLED === "true") {
            if (await hasRunningPodMatching("tekton-pipelines", /tekton/)) {
                return {
                    state: "reachable",
                    latencyMs: 0,
                    message: "Tekton installed (BUILD_BACKEND=jenkins — switch to tekton to build)"
                };
            }
        }
        return {
            state: "skipped",
            message: "No URL configured"
        };
    }
    const href = item.href;
    switch (item.id) {
        case "k8s-control-plane": {
            const t0 = Date.now();
            if (env.KUBERNETES_ENABLED === "true") {
                const api = getCoreV1Api();
                if (api) {
                    try {
                        await api.listNode();
                        return {
                            state: "reachable",
                            latencyMs: Date.now() - t0,
                            message: "Cluster API reachable (kubeconfig credentials)"
                        };
                    }
                    catch (error) {
                        return {
                            state: "unreachable",
                            latencyMs: Date.now() - t0,
                            message: error instanceof Error ? error.message : String(error)
                        };
                    }
                }
                return {
                    state: "unreachable",
                    latencyMs: Date.now() - t0,
                    message: "KUBERNETES_ENABLED is true but the API client could not be created (check KUBE_CONFIG_PATH and kubeconfig)."
                };
            }
            if (!href) {
                return {
                    state: "skipped",
                    message: "Not configured"
                };
            }
            return httpProbe(href, {}, {
                itemId: item.id,
                bypassHostRemap: probeHostIsRemapSource(href, env.INTEGRATIONS_PROBE_HOST_REMAP)
            });
        }
        case "ingress-nginx": {
            const probeOnly = env.INGRESS_NGINX_PROBE_URL.trim();
            const probeUrl = probeOnly || href;
            if (!probeUrl) {
                return {
                    state: "skipped",
                    message: "Not configured"
                };
            }
            const bypassIngress = Boolean(probeOnly) || probeHostIsRemapSource(probeUrl, env.INTEGRATIONS_PROBE_HOST_REMAP);
            const r = await httpProbe(probeUrl, {}, {
                itemId: item.id,
                bypassHostRemap: bypassIngress
            });
            if (r.state === "reachable") {
                return r;
            }
            if (r.message?.startsWith("HTTP 404")) {
                return {
                    state: "reachable",
                    latencyMs: r.latencyMs,
                    message: "HTTP 404 — controller is up (no default route for /)"
                };
            }
            return r;
        }
        case "jenkins": {
            if (!realValueOrEmpty(env.JENKINS_BASE_URL)) {
                return {
                    state: "skipped",
                    message: "Not configured"
                };
            }
            const useProbeUrl = Boolean(realValueOrEmpty(env.JENKINS_PROBE_URL));
            const probeBase = realValueOrEmpty(env.JENKINS_PROBE_URL).replace(/\/+$/, "") || env.JENKINS_BASE_URL.replace(/\/+$/, "");
            const jenkinsProbeUrl = `${probeBase}/api/json`;
            const bypassJenkins = useProbeUrl || probeHostIsRemapSource(jenkinsProbeUrl, env.INTEGRATIONS_PROBE_HOST_REMAP);
            return httpProbe(jenkinsProbeUrl, {
                headers: {
                    Authorization: jenkinsAuthHeader()
                }
            }, { itemId: item.id, bypassHostRemap: bypassJenkins });
        }
        case "argocd": {
            if (!realValueOrEmpty(env.ARGOCD_BASE_URL)) {
                return {
                    state: "skipped",
                    message: "Not configured"
                };
            }
            if (!realValueOrEmpty(env.ARGOCD_AUTH_TOKEN)) {
                return {
                    state: "skipped",
                    message: "Set ARGOCD_AUTH_TOKEN (or ARGOCD_TOKEN) to probe the Argo CD API"
                };
            }
            const base = env.ARGOCD_BASE_URL.replace(/\/+$/, "");
            const t0 = Date.now();
            try {
                const res = await argocdIntegrationFetch(`${base}/api/version`, {
                    method: "GET",
                    headers: {
                        Authorization: `Bearer ${env.ARGOCD_AUTH_TOKEN.trim()}`
                    }
                });
                const ms = Date.now() - t0;
                if (res.ok) {
                    return {
                        state: "reachable",
                        latencyMs: ms
                    };
                }
                return {
                    state: "unreachable",
                    latencyMs: ms,
                    message: `HTTP ${res.status}`
                };
            }
            catch (error) {
                const raw = integrationProbeErrorMessage(error);
                return {
                    state: "unreachable",
                    latencyMs: Date.now() - t0,
                    message: raw
                };
            }
        }
        case "prometheus": {
            const promBase = realValueOrEmpty(env.PROMETHEUS_PROBE_URL).replace(/\/+$/, "") || href.replace(/\/+$/, "");
            const bypass = Boolean(realValueOrEmpty(env.PROMETHEUS_PROBE_URL)) ||
                probeHostIsRemapSource(promBase, env.INTEGRATIONS_PROBE_HOST_REMAP);
            return httpProbe(joinUrl(promBase, "/-/ready"), {}, { itemId: item.id, bypassHostRemap: bypass });
        }
        case "alertmanager": {
            const amBase = realValueOrEmpty(env.ALERTMANAGER_PROBE_URL).replace(/\/+$/, "") || href.replace(/\/+$/, "");
            const bypass = Boolean(realValueOrEmpty(env.ALERTMANAGER_PROBE_URL)) ||
                probeHostIsRemapSource(amBase, env.INTEGRATIONS_PROBE_HOST_REMAP);
            return httpProbe(joinUrl(amBase, "/-/healthy"), {}, { itemId: item.id, bypassHostRemap: bypass });
        }
        case "pushgateway": {
            const node = labNodeBase();
            return probeMany([
                realValueOrEmpty(env.PUSHGATEWAY_PROBE_URL),
                href,
                node ? `${node}:31481` : ""
            ], "/-/healthy", { itemId: item.id, bypassHostRemap: true });
        }
        case "grafana": {
            const node = labNodeBase();
            return probeMany([
                realValueOrEmpty(env.GRAFANA_PROBE_URL),
                href,
                node ? `${node}:32383` : "",
                node ? `${node}:30082` : "",
                "http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80"
            ], "/api/health", { itemId: item.id, bypassHostRemap: true });
        }
        case "elasticsearch": {
            const node = labNodeBase();
            const http = await probeMany([
                "http://elasticsearch-master.monitoring.svc.cluster.local:9200",
                href,
                node ? `${node}:32231` : ""
            ], "/_cluster/health", { itemId: item.id, bypassHostRemap: true });
            if (http.state === "reachable") {
                return http;
            }
            if (await hasRunningPodMatching("monitoring", /^elasticsearch-master-/)) {
                return {
                    state: "reachable",
                    latencyMs: 0,
                    message: "Elasticsearch pod running (cluster HTTP probe failed — TLS/security may block probes)"
                };
            }
            return http;
        }
        case "nexus": {
            const node = labNodeBase();
            return probeMany([
                href,
                "http://nexus-nexus-repository-manager.devtools.svc.cluster.local:8081",
                node ? `${node}:31566` : ""
            ], "/", { itemId: item.id, bypassHostRemap: true });
        }
        case "artifactory": {
            const node = labNodeBase();
            return probeMany([
                href,
                realValueOrEmpty(env.ARTIFACTORY_URL),
                "http://artifactory.devtools.svc.cluster.local:8082",
                node ? `${node}:31754` : ""
            ], "/artifactory/api/system/ping", { itemId: item.id, bypassHostRemap: true });
        }
        case "owasp-zap": {
            const node = labNodeBase();
            return probeMany([
                href,
                "http://zap.security.svc.cluster.local:8080",
                node ? `${node}:32629` : ""
            ], "/", { itemId: item.id, bypassHostRemap: true });
        }
        case "sonarqube": {
            const headers: Record<string, string> = {};
            if (realValueOrEmpty(env.SONAR_TOKEN)) {
                headers.Authorization = `Basic ${Buffer.from(`${env.SONAR_TOKEN.trim()}:`).toString("base64")}`;
            }
            const sonarBase = realValueOrEmpty(env.SONAR_PROBE_URL).replace(/\/+$/, "") || href.replace(/\/+$/, "");
            const bypassSonar = Boolean(realValueOrEmpty(env.SONAR_PROBE_URL)) ||
                probeHostIsRemapSource(sonarBase, env.INTEGRATIONS_PROBE_HOST_REMAP);
            const sonarTimeout = Math.max(env.PLATFORM_INTEGRATION_PROBE_TIMEOUT_MS, 45000);
            return httpProbe(joinUrl(sonarBase, "/api/system/status"), { headers }, {
                itemId: item.id,
                timeoutMs: sonarTimeout,
                bypassHostRemap: bypassSonar
            });
        }
        case "dependency-track": {
            const dtBase = href.replace(/\/+$/, "");
            const bypassDt = probeHostIsRemapSource(dtBase, env.INTEGRATIONS_PROBE_HOST_REMAP);
            const node = labNodeBase();
            return probeMany([
                "http://dtrack-dependency-track-api-server.dependency-track.svc.cluster.local:8080",
                dtBase,
                node ? `${node}:31428` : ""
            ], "/api/version", {
                itemId: item.id,
                bypassHostRemap: bypassDt
            });
        }
        case "trivy-policy": {
            const probeCtx = {
                itemId: item.id,
                bypassHostRemap: true
            } as const;
            const candidates = [
                "http://harbor-trivy.harbor.svc.cluster.local:8080",
                realValueOrEmpty(env.TRIVY_PROBE_URL).replace(/\/+$/, ""),
                href.replace(/\/+$/, ""),
                env.APPS_PUBLIC_LAB_NODE_IP.trim()
                    ? `http://${env.APPS_PUBLIC_LAB_NODE_IP.trim()}:30954`
                    : "",
                "http://trivy-service.security.svc.cluster.local:4954"
            ].filter(Boolean);
            const seen = new Set<string>();
            const paths = [
                "/api/v1/metadata",
                "/probe/healthy",
                "/probe/ready",
                "/healthz",
                "/health",
                "/"
            ];
            for (const base of candidates) {
                if (seen.has(base)) {
                    continue;
                }
                seen.add(base);
                for (const path of paths) {
                    const r = await httpProbe(joinUrl(base, path), {}, probeCtx);
                    if (r.state === "reachable") {
                        return r;
                    }
                }
            }
            if (await hasRunningPodMatching("harbor", /trivy/i)) {
                return {
                    state: "reachable",
                    latencyMs: 0,
                    message: "Harbor Trivy scanner pod running (use Harbor image scan; standalone NodePort may be absent)"
                };
            }
            return {
                state: "unreachable",
                message: "Trivy not responding on configured URLs"
            };
        }
        case "dockerhub": {
            if (!href) {
                return { state: "skipped", message: "DOCKERHUB_USERNAME not set" };
            }
            const r = await httpProbe(href, {}, { itemId: item.id, timeoutMs: 12000 });
            if (r.state === "reachable") {
                return r;
            }
            return {
                state: "skipped",
                message: "Docker Hub profile not reachable from cluster (optional for lab)"
            };
        }
        case "harbor-dockerhub": {
            const headers: Record<string, string> = {};
            const hb = harborAuthHeader();
            if (hb) {
                headers.Authorization = hb;
            }
            const harborBase = realValueOrEmpty(env.HARBOR_PROBE_URL).replace(/\/+$/, "") || href.replace(/\/+$/, "");
            const bypassHarbor = Boolean(realValueOrEmpty(env.HARBOR_PROBE_URL)) ||
                probeHostIsRemapSource(harborBase, env.INTEGRATIONS_PROBE_HOST_REMAP);
            const ping = await httpProbe(joinUrl(harborBase, "/api/v2.0/ping"), { headers }, {
                itemId: item.id,
                bypassHostRemap: bypassHarbor
            });
            if (ping.state === "reachable") {
                return ping;
            }
            return httpProbe(harborBase, { headers }, { itemId: item.id, bypassHostRemap: bypassHarbor });
        }
        case "cert-manager": {
            const cmProbe = realValueOrEmpty(env.CERT_MANAGER_PROBE_URL).replace(/\/+$/, "");
            const bypass = (Boolean(cmProbe) && href.replace(/\/+$/, "") === cmProbe) ||
                probeHostIsRemapSource(href, env.INTEGRATIONS_PROBE_HOST_REMAP);
            const http = await httpProbe(href, {}, {
                itemId: item.id,
                bypassHostRemap: bypass
            });
            if (http.state === "reachable") {
                return http;
            }
            if (process.env.CERT_MANAGER_INSTALLED === "true" && await hasRunningPodMatching("cert-manager", /cert-manager/)) {
                return {
                    state: "reachable",
                    latencyMs: 0,
                    message: "cert-manager running in-cluster (webhook not HTTP-probed)"
                };
            }
            return http;
        }
        case "kube-state-metrics":
        case "node-exporter": {
            const path = item.id === "node-exporter" ? "/metrics" : "/metrics";
            const http = await httpProbe(joinUrl(href, path), {}, { itemId: item.id, bypassHostRemap: true });
            if (http.state === "reachable") {
                return http;
            }
            if (item.id === "node-exporter" && await hasRunningPodMatching("monitoring", /node-exporter/)) {
                return {
                    state: "reachable",
                    latencyMs: 0,
                    message: "Node exporter DaemonSet running (scraped by Prometheus)"
                };
            }
            if (item.id === "kube-state-metrics" && await hasRunningPodMatching("monitoring", /kube-state-metrics/)) {
                return {
                    state: "reachable",
                    latencyMs: 0,
                    message: "kube-state-metrics running in-cluster"
                };
            }
            return http;
        }
        case "kibana": {
            const http = await probeMany([href, joinUrl(href, "/api/status")], "/", { itemId: item.id, bypassHostRemap: true });
            if (http.state === "reachable") {
                return http;
            }
            if (await hasRunningPodMatching("monitoring", /kibana/)) {
                return {
                    state: "reachable",
                    latencyMs: 0,
                    message: "Kibana pod running"
                };
            }
            return http;
        }
        case "tekton": {
            const http = await httpProbe(href, {}, { itemId: item.id, bypassHostRemap: true });
            if (http.state === "reachable") {
                return http;
            }
            if (process.env.TEKTON_INSTALLED === "true" && await hasRunningPodMatching("tekton-pipelines", /tekton/)) {
                return {
                    state: "reachable",
                    latencyMs: 0,
                    message: "Tekton control plane running"
                };
            }
            return http;
        }
        case "kubewarden": {
            const http = await httpProbe(href, {}, { itemId: item.id, bypassHostRemap: true });
            if (http.state === "reachable") {
                return http;
            }
            if (process.env.KUBEWARDEN_INSTALLED === "true" && await hasRunningPodMatching("kubewarden", /policy-server|kubewarden|audit-scanner/)) {
                return {
                    state: "reachable",
                    latencyMs: 0,
                    message: "Kubewarden policy server running"
                };
            }
            return http;
        }
        case "opa-gatekeeper": {
            if (process.env.GATEKEEPER_INSTALLED === "true" && await hasRunningPodMatching("gatekeeper-system", /gatekeeper/)) {
                const http = await httpProbe(href, {}, { itemId: item.id, bypassHostRemap: true });
                if (http.state === "reachable") {
                    return http;
                }
                return {
                    state: "reachable",
                    latencyMs: 0,
                    message: "Gatekeeper controller running (POLICY_ENGINE=kyverno for admission)"
                };
            }
            return httpProbe(href, {}, { itemId: item.id, bypassHostRemap: true });
        }
        case "calico": {
            if (process.env.CALICO_INSTALLED === "true") {
                return {
                    state: "reachable",
                    latencyMs: 0,
                    message: "Calico / Tigera CNI installed"
                };
            }
            return httpProbe(href, {}, { itemId: item.id });
        }
        case "vault": {
            const healthPath = joinUrl(href, "/v1/sys/health?standbyok=true&drsecondarycode=200");
            const va = realValueOrEmpty(env.VAULT_ADDR).replace(/\/+$/, "");
            const bypass = (Boolean(va) && href.replace(/\/+$/, "") === va) ||
                probeHostIsRemapSource(healthPath, env.INTEGRATIONS_PROBE_HOST_REMAP);
            return httpProbe(healthPath, {}, {
                itemId: item.id,
                bypassHostRemap: bypass
            });
        }
        case "consul": {
            return httpProbe(joinUrl(href, "/v1/status/leader"), {}, { itemId: item.id });
        }
        case "nomad": {
            return httpProbe(joinUrl(href, "/v1/status/leader"), {}, { itemId: item.id });
        }
        case "github":
        case "gitops-repo": {
            const token = realValueOrEmpty(env.GITOPS_REPO_TOKEN);
            const repoUrl = realValueOrEmpty(env.GITOPS_REPO_URL);
            if (!token || !repoUrl) {
                return {
                    state: "skipped",
                    message: "Set GITOPS_REPO_URL and GITOPS_REPO_TOKEN to probe GitHub API"
                };
            }
            try {
                const u = new URL(repoUrl);
                if (u.hostname !== "github.com") {
                    return httpProbe(href, {}, { itemId: item.id });
                }
                const parts = u.pathname.split("/").filter(Boolean);
                if (parts.length < 2) {
                    return httpProbe(href, {}, { itemId: item.id });
                }
                const apiPath = `/repos/${parts[0]}/${parts[1]}`;
                return httpProbe(`https://api.github.com${apiPath}`, {
                    headers: {
                        Authorization: `Bearer ${token}`,
                        Accept: "application/vnd.github+json"
                    }
                }, { itemId: item.id });
            }
            catch {
                return httpProbe(href, {}, { itemId: item.id });
            }
        }
        case "opa-server": {
            if (!env.OPA_EVAL_URL.trim()) {
                return {
                    state: "skipped",
                    message: "OPA_EVAL_URL not set"
                };
            }
            return httpProbe(env.OPA_EVAL_URL.trim(), {}, { itemId: item.id });
        }
        default:
            return httpProbe(href, {}, { itemId: item.id });
    }
}
async function runPool<T, R>(items: T[], limit: number, worker: (item: T) => Promise<R>): Promise<R[]> {
    const results: R[] = new Array(items.length);
    let next = 0;
    async function runOne(): Promise<void> {
        for (;;) {
            const i = next++;
            if (i >= items.length) {
                return;
            }
            results[i] = await worker(items[i]!);
        }
    }
    const workers = Array.from({ length: Math.min(limit, items.length) }, () => runOne());
    await Promise.all(workers);
    return results;
}
export async function attachIntegrationHealth(payload: PlatformIntegrationsResponse): Promise<void> {
    type Entry = {
        item: PlatformIntegrationItem;
    };
    const flat: Entry[] = [];
    for (const cat of payload.categories) {
        for (const item of cat.items) {
            flat.push({ item });
        }
    }
    const outcomes = await runPool(flat, CONCURRENCY, async ({ item }) => probeByItemId(item));
    outcomes.forEach((reachability, idx) => {
        flat[idx]!.item.reachability = reachability;
    });
}
