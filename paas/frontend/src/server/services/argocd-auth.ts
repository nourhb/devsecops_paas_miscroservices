import { env } from "@/server/config/env";
import { argocdIntegrationFetch } from "@/server/http/argocd-fetch";

let cachedSessionToken: string | null = null;
let cachedSessionExpiresAt = 0;

function getArgoCdApiBase(): string {
    return env.ARGOCD_BASE_URL.trim().replace(/\/+$/, "");
}

function configuredPassword(): string {
    return env.ARGOCD_PASSWORD.trim();
}

function configuredUsername(): string {
    return env.ARGOCD_USERNAME.trim() || "admin";
}

export function clearArgoCdSessionCache(): void {
    cachedSessionToken = null;
    cachedSessionExpiresAt = 0;
}

async function loginForSessionToken(): Promise<string | null> {
    const base = getArgoCdApiBase();
    const password = configuredPassword();
    if (!base || !password) {
        return null;
    }
    const response = await argocdIntegrationFetch(`${base}/api/v1/session`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            username: configuredUsername(),
            password
        })
    });
    if (!response.ok) {
        return null;
    }
    const payload = (await response.json()) as {
        token?: string;
    };
    const token = payload.token?.trim();
    if (!token) {
        return null;
    }
    cachedSessionToken = token;
    cachedSessionExpiresAt = Date.now() + 25 * 60_000;
    return token;
}

export async function resolveArgoCdAuthToken(): Promise<string | null> {
    const staticToken = env.ARGOCD_AUTH_TOKEN.trim();
    if (staticToken) {
        return staticToken;
    }
    if (cachedSessionToken && Date.now() < cachedSessionExpiresAt) {
        return cachedSessionToken;
    }
    return loginForSessionToken();
}

export async function resolveArgoCdAuthHeader(): Promise<Record<string, string> | null> {
    let token = await resolveArgoCdAuthToken();
    if (!token) {
        return null;
    }
    return { Authorization: `Bearer ${token}` };
}

export async function argocdFetchWithAuth(url: string, init: RequestInit = {}): Promise<Response> {
    const baseHeaders = await resolveArgoCdAuthHeader();
    if (!baseHeaders) {
        throw new Error("Argo CD auth is not configured");
    }
    const mergedHeaders = {
        ...baseHeaders,
        ...(init.headers as Record<string, string> | undefined)
    };
    let response = await argocdIntegrationFetch(url, { ...init, headers: mergedHeaders });
    if (response.status !== 401 && response.status !== 403) {
        return response;
    }
    clearArgoCdSessionCache();
    const sessionToken = await loginForSessionToken();
    if (!sessionToken) {
        return response;
    }
    response = await argocdIntegrationFetch(url, {
        ...init,
        headers: {
            Authorization: `Bearer ${sessionToken}`,
            ...(init.headers as Record<string, string> | undefined)
        }
    });
    return response;
}
