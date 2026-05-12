import { env } from "@/server/config/env";
import { isPlaceholderValue, realValueOrEmpty } from "@/server/config/real-values";
import { argocdIntegrationFetch } from "@/server/http/argocd-fetch";
import { integrationFetch } from "@/server/http/integration-fetch";
import { getCoreV1Api } from "@/server/integrations/kubernetes-client";
import type { PlatformIntegrationItem, PlatformIntegrationReachability, PlatformIntegrationsResponse } from "@/types";
const PROBE_TIMEOUT_MS = 4500;
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
async function httpProbe(url: string, init: RequestInit = {}): Promise<PlatformIntegrationReachability> {
    const t0 = Date.now();
    try {
        const res = await integrationFetch(url, {
            method: "GET",
            redirect: "follow",
            ...init
        }, PROBE_TIMEOUT_MS);
        const ms = Date.now() - t0;
        if (res.ok || res.status === 301 || res.status === 302 || res.status === 401 || res.status === 403) {
            return {
                state: "reachable",
                latencyMs: ms,
                message: res.ok ? undefined : `HTTP ${res.status}`
            };
        }
        return {
            state: "unreachable",
            latencyMs: ms,
            message: typeof res.status === "number" && res.status > 0 ? `HTTP ${res.status}` : "Empty response"
        };
    }
    catch (error) {
        const ms = Date.now() - t0;
        const message = error instanceof Error ? error.message : String(error);
        return {
            state: "unreachable",
            latencyMs: ms,
            message
        };
    }
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
            return httpProbe(joinUrl(base, "/artifacts"));
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
        return {
            state: "skipped",
            message: "No URL configured"
        };
    }
    const href = item.href;
    switch (item.id) {
        case "jenkins": {
            if (!realValueOrEmpty(env.JENKINS_BASE_URL)) {
                return {
                    state: "skipped",
                    message: "Not configured"
                };
            }
            const base = env.JENKINS_BASE_URL.replace(/\/+$/, "");
            return httpProbe(`${base}/api/json`, {
                headers: {
                    Authorization: jenkinsAuthHeader()
                }
            });
        }
        case "argocd": {
            if (!realValueOrEmpty(env.ARGOCD_BASE_URL) || !realValueOrEmpty(env.ARGOCD_AUTH_TOKEN)) {
                return {
                    state: "skipped",
                    message: "Not configured"
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
                    message: `HTTP ${res.status} — check URL, token, and ARGOCD_TLS_SKIP_VERIFY or INTEGRATIONS_TLS_SKIP_VERIFY for self-signed certs`
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
        case "prometheus": {
            return httpProbe(joinUrl(href, "/-/ready"));
        }
        case "alertmanager": {
            return httpProbe(joinUrl(href, "/-/healthy"));
        }
        case "pushgateway": {
            return httpProbe(joinUrl(href, "/-/healthy"));
        }
        case "grafana": {
            return httpProbe(joinUrl(href, "/api/health"));
        }
        case "sonarqube": {
            const headers: Record<string, string> = {};
            if (realValueOrEmpty(env.SONAR_TOKEN)) {
                headers.Authorization = `Basic ${Buffer.from(`${env.SONAR_TOKEN.trim()}:`).toString("base64")}`;
            }
            return httpProbe(joinUrl(href, "/api/system/status"), { headers });
        }
        case "dependency-track": {
            if (!realValueOrEmpty(env.DEPENDENCY_TRACK_API_KEY)) {
                return httpProbe(joinUrl(href, "/api/version"));
            }
            return httpProbe(joinUrl(href, "/api/version"), {
                headers: {
                    "X-Api-Key": env.DEPENDENCY_TRACK_API_KEY.trim()
                }
            });
        }
        case "trivy-policy": {
            const h = await httpProbe(joinUrl(href, "/healthz"));
            if (h.state === "reachable") {
                return h;
            }
            return httpProbe(joinUrl(href, "/"));
        }
        case "harbor-dockerhub": {
            const headers: Record<string, string> = {};
            const hb = harborAuthHeader();
            if (hb) {
                headers.Authorization = hb;
            }
            const ping = await httpProbe(joinUrl(href, "/api/v2.0/ping"), { headers });
            if (ping.state === "reachable") {
                return ping;
            }
            return httpProbe(href, { headers });
        }
        case "vault": {
            return httpProbe(joinUrl(href, "/v1/sys/health?standbyok=true&drsecondarycode=200"));
        }
        case "consul": {
            return httpProbe(joinUrl(href, "/v1/status/leader"));
        }
        case "nomad": {
            return httpProbe(joinUrl(href, "/v1/status/leader"));
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
                    return httpProbe(href);
                }
                const parts = u.pathname.split("/").filter(Boolean);
                if (parts.length < 2) {
                    return httpProbe(href);
                }
                const apiPath = `/repos/${parts[0]}/${parts[1]}`;
                return httpProbe(`https://api.github.com${apiPath}`, {
                    headers: {
                        Authorization: `Bearer ${token}`,
                        Accept: "application/vnd.github+json"
                    }
                });
            }
            catch {
                return httpProbe(href);
            }
        }
        case "opa-server": {
            if (!env.OPA_EVAL_URL.trim()) {
                return {
                    state: "skipped",
                    message: "OPA_EVAL_URL not set"
                };
            }
            return httpProbe(env.OPA_EVAL_URL.trim());
        }
        default:
            return httpProbe(href);
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
