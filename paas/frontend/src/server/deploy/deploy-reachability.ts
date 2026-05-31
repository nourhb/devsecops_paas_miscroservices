import { env } from "@/server/config/env";
import { integrationFetch } from "@/server/http/integration-fetch";

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function probeAppUrlReachability(url: string, options?: {
    timeoutMs?: number;
    maxAttempts?: number;
    delayMs?: number;
}): Promise<{
    reachable: boolean;
    statusCode: number | null;
    error?: string;
}> {
    const trimmed = url.trim();
    if (!trimmed) {
        return { reachable: false, statusCode: null, error: "empty_url" };
    }
    const maxAttempts = Math.max(1, options?.maxAttempts ?? 24);
    const delayMs = Math.max(1000, options?.delayMs ?? env.PAAS_DEPLOY_HTTP_POLL_MS);
    const perAttemptMs = Math.max(3000, options?.timeoutMs ?? env.APPS_REACHABILITY_TIMEOUT_MS);
    let lastStatus: number | null = null;
    let lastError = "unreachable";
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
        for (const method of ["GET", "HEAD"] as const) {
            try {
                const response = await integrationFetch(trimmed, {
                    method,
                    redirect: "follow",
                    cache: "no-store"
                }, perAttemptMs);
                lastStatus = response.status;
                if (response.status >= 200 && response.status < 400) {
                    return { reachable: true, statusCode: response.status };
                }
                if (response.status === 404 && attempt < maxAttempts) {
                    lastError = "ingress_pending";
                    break;
                }
            }
            catch (error) {
                lastError = error instanceof Error ? error.message : String(error);
            }
        }
        if (attempt < maxAttempts) {
            await sleep(delayMs);
        }
    }
    return { reachable: false, statusCode: lastStatus, error: lastError };
}
