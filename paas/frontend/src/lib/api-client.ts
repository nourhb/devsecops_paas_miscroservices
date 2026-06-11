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
apiClient.interceptors.request.use((config) => {
    const token = authStorage.getToken();
    if (token) {
        config.headers = config.headers || {};
        config.headers.Authorization = `Bearer ${token}`;
    }
    return config;
});
apiClient.interceptors.response.use((response) => response, (error) => {
    const status = error.response?.status;
    if (status === 503) {
        return Promise.reject(error);
    }
    if (status === 401) {
        const requestUrl = String(error.config?.url || "");
        const isAuthAttempt = /\/api\/auth\/(login|register|session)/.test(requestUrl);
        if (!isAuthAttempt) {
            authStorage.clear();
            if (typeof window !== "undefined") {
                const publicPaths = new Set(["/login", "/register", "/forgot-password", "/reset-password", "/verify-email"]);
                if (!publicPaths.has(window.location.pathname)) {
                    window.location.href = "/login";
                }
            }
        }
    }
    return Promise.reject(error);
});
export default apiClient;
