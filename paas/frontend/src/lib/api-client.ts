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
