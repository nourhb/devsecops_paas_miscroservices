import axios from "axios";
import { authStorage } from "@/lib/auth-storage";

function resolveBrowserApiBaseUrl(): string {
    const raw = (process.env.NEXT_PUBLIC_API_BASE_URL || process.env.NEXT_PUBLIC_API_URL || "").trim();
    if (!raw) {
        return "";
    }
    let base = raw.replace(/\/+$/, "");
    if (base.endsWith("/api")) {
        base = base.slice(0, -4);
    }
    return base;
}

const apiClient = axios.create({
    baseURL: resolveBrowserApiBaseUrl(),
    timeout: 30000,
    withCredentials: true,
    headers: {
        "Content-Type": "application/json"
    }
});

export const PIPELINE_TRIGGER_TIMEOUT_MS = Number(process.env.NEXT_PUBLIC_PIPELINE_TRIGGER_TIMEOUT_MS || 180000);

let sessionProbe: Promise<boolean> | null = null;

async function probeSessionAlive(): Promise<boolean> {
    if (!sessionProbe) {
        sessionProbe = apiClient
            .get("/api/auth/session")
            .then(() => true)
            .catch(() => false)
            .finally(() => {
                sessionProbe = null;
            });
    }
    return sessionProbe;
}

apiClient.interceptors.request.use((config) => {
    const token = authStorage.getToken();
    if (token) {
        config.headers = config.headers || {};
        config.headers.Authorization = `Bearer ${token}`;
    }
    return config;
});

apiClient.interceptors.response.use((response) => response, async (error) => {
    if (error.response?.status === 401) {
        const requestUrl = String(error.config?.url || "");
        const publicPaths = new Set(["/login", "/register", "/forgot-password", "/reset-password", "/verify-email"]);
        if (requestUrl.includes("/api/auth/session")) {
            authStorage.clear();
            return Promise.reject(error);
        }

        const alive = await probeSessionAlive();
        if (!alive) {
            authStorage.clear();
            if (typeof window !== "undefined" && !publicPaths.has(window.location.pathname)) {
                window.location.href = "/login";
            }
        }
    }
    return Promise.reject(error);
});

export default apiClient;

const LAB_JENKINS_PUBLIC = (typeof process !== "undefined" && process.env.NEXT_PUBLIC_JENKINS_URL?.replace(/\/+$/, "")) ||
    (typeof process !== "undefined" && process.env.NEXT_PUBLIC_JENKINS_PROBE_URL?.replace(/\/+$/, "")) ||
    "";

export function jenkinsUrlForBrowser(url: string | null | undefined, options?: {
    buildNumber?: number | null;
    jobName?: string;
}): string | null {
    const pub = LAB_JENKINS_PUBLIC;
    const job = options?.jobName?.trim() || "paas-deploy";
    const bn = options?.buildNumber;
    if (url?.trim()) {
        if (/\.svc\.cluster\.local/i.test(url)) {
            if (pub) {
                try {
                    return `${pub}${new URL(url).pathname}`;
                }
                catch {
                }
            }
            if (bn != null) {
                return pub ? `${pub}/job/${job}/${bn}` : null;
            }
            return null;
        }
        return url.trim();
    }
    if (pub && bn != null) {
        return `${pub}/job/${job}/${bn}`;
    }
    return pub || null;
}

function pickBody(err: unknown): Record<string, unknown> | null {
    if (typeof err !== "object" || err === null || !("response" in err)) {
        return null;
    }
    const body = (err as { response?: { data?: unknown } }).response?.data;
    if (typeof body !== "object" || body === null) {
        return null;
    }
    return body as Record<string, unknown>;
}

export function queryHttpMessage(err: unknown, fallback: string): string {
    const body = pickBody(err);
    const msg = body?.message;
    if (typeof msg === "string" && msg.trim()) {
        return msg;
    }
    if (err instanceof Error && err.message.trim()) {
        if (/timeout.*exceeded/i.test(err.message) && !body) {
            return "Request timed out while syncing with Jenkins. The run may still have started — refresh status or open Jenkins.";
        }
        return err.message;
    }
    return fallback;
}

export function queryHttpDetails(err: unknown): string | null {
    const body = pickBody(err);
    const d = body?.details;
    return typeof d === "string" && d.trim() ? d : null;
}

export function queryHttpData(err: unknown): Record<string, unknown> | null {
    return pickBody(err);
}
