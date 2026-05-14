import { env } from "@/server/config/env";
import { isPlaceholderValue, realValueOrEmpty } from "@/server/config/real-values";
import { argocdIntegrationFetch } from "@/server/http/argocd-fetch";
import { appendUnreachableProbeHint } from "@/server/http/integration-probe-hints";
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
    /** When true, do not apply INTEGRATIONS_PROBE_HOST_REMAP (use for *_PROBE_URL bases). */
    bypassHostRemap?: boolean;
    /** Override default PLATFORM_INTEGRATION_PROBE_TIMEOUT_MS (e.g. cold SonarQube). */
    timeoutMs?: number;
};
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
            message: appendUnreachableProbeHint(ctx?.itemId, url, raw)
        };
    }
    catch (error) {
        const ms = Date.now() - t0;
        const message = integrationProbeErrorMessage(error);
        return {
            state: "unreachable",
            latencyMs: ms,
            message: appendUnreachableProbeHint(ctx?.itemId, url, message)
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
        if (item.id === "project-security" || item.id === "nodejs-express" || item.id === "python" || item.id === "java-static") {
            return {
                state: "reachable",
                message: "In-app"
            };
        }
        if (item.id === "nextjs-ui") {
            return {
                state: "reachable",
                message: "This application"
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
            return httpProbe(href, {}, { itemId: item.id });
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
                    message: appendUnreachableProbeHint(
                        "argocd",
                        base,
                        `HTTP ${res.status} — check URL, token, and ARGOCD_TLS_SKIP_VERIFY or INTEGRATIONS_TLS_SKIP_VERIFY for self-signed certs`
                    )
                };
            }
            catch (error) {
                const raw = integrationProbeErrorMessage(error);
                return {
                    state: "unreachable",
                    latencyMs: Date.now() - t0,
                    message: appendUnreachableProbeHint("argocd", base, raw)
                };
            }
        }
        case "prometheus": {
            return httpProbe(joinUrl(href, "/-/ready"), {}, { itemId: item.id });
        }
        case "alertmanager": {
            return httpProbe(joinUrl(href, "/-/healthy"), {}, { itemId: item.id });
        }
        case "pushgateway": {
            const useProbeUrl = Boolean(realValueOrEmpty(env.PUSHGATEWAY_PROBE_URL));
            const base = realValueOrEmpty(env.PUSHGATEWAY_PROBE_URL).replace(/\/+$/, "") || href.replace(/\/+$/, "");
            const pgUrl = joinUrl(base, "/-/healthy");
            const bypassPg = useProbeUrl || probeHostIsRemapSource(pgUrl, env.INTEGRATIONS_PROBE_HOST_REMAP);
            return httpProbe(pgUrl, {}, { itemId: item.id, bypassHostRemap: bypassPg });
        }
        case "grafana": {
            return httpProbe(joinUrl(href, "/api/health"), {}, { itemId: item.id });
        }
        case "sonarqube": {
            const headers: Record<string, string> = {};
            if (realValueOrEmpty(env.SONAR_TOKEN)) {
                headers.Authorization = `Basic ${Buffer.from(`${env.SONAR_TOKEN.trim()}:`).toString("base64")}`;
            }
            const sonarTimeout = Math.max(env.PLATFORM_INTEGRATION_PROBE_TIMEOUT_MS, 45000);
            return httpProbe(joinUrl(href, "/api/system/status"), { headers }, { itemId: item.id, timeoutMs: sonarTimeout });
        }
        case "dependency-track": {
            if (!realValueOrEmpty(env.DEPENDENCY_TRACK_API_KEY)) {
                return httpProbe(joinUrl(href, "/api/version"), {}, { itemId: item.id });
            }
            return httpProbe(joinUrl(href, "/api/version"), {
                headers: {
                    "X-Api-Key": env.DEPENDENCY_TRACK_API_KEY.trim()
                }
            }, { itemId: item.id });
        }
        case "trivy-policy": {
            const trivyBase = realValueOrEmpty(env.TRIVY_PROBE_URL).replace(/\/+$/, "") || href.replace(/\/+$/, "");
            const healthUrl = joinUrl(trivyBase, "/healthz");
            const probeCtx = {
                itemId: item.id,
                bypassHostRemap: true
            } as const;
            const h = await httpProbe(healthUrl, {}, probeCtx);
            if (h.state === "reachable") {
                return h;
            }
            return httpProbe(joinUrl(trivyBase, "/"), {}, probeCtx);
        }
        case "harbor-dockerhub": {
            const headers: Record<string, string> = {};
            const hb = harborAuthHeader();
            if (hb) {
                headers.Authorization = hb;
            }
            const ping = await httpProbe(joinUrl(href, "/api/v2.0/ping"), { headers }, { itemId: item.id });
            if (ping.state === "reachable") {
                return ping;
            }
            return httpProbe(href, { headers }, { itemId: item.id });
        }
        case "cert-manager": {
            const cmProbe = realValueOrEmpty(env.CERT_MANAGER_PROBE_URL).replace(/\/+$/, "");
            const bypass =
                (Boolean(cmProbe) && href.replace(/\/+$/, "") === cmProbe) ||
                probeHostIsRemapSource(href, env.INTEGRATIONS_PROBE_HOST_REMAP);
            return httpProbe(href, {}, {
                itemId: item.id,
                bypassHostRemap: bypass
            });
        }
        case "vault": {
            const healthPath = joinUrl(href, "/v1/sys/health?standbyok=true&drsecondarycode=200");
            const va = realValueOrEmpty(env.VAULT_ADDR).replace(/\/+$/, "");
            const bypass =
                (Boolean(va) && href.replace(/\/+$/, "") === va) ||
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
