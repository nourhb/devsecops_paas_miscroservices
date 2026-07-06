import { INTEGRATION_HTTP_TIMEOUT_MS } from "@/server/constants/deploy";
import { env } from "@/server/config/env";
import { ApiError } from "@/server/http/response";
import { Agent, fetch as undiciFetch } from "undici";
const insecureAgent = new Agent({
    connect: {
        rejectUnauthorized: false
    }
});
export type IntegrationFetchOptions = {
    timeoutMs?: number;
    bypassHostRemap?: boolean;
};
function resolveIntegrationFetchOptions(third?: number | IntegrationFetchOptions): {
    timeoutMs: number;
    bypassHostRemap: boolean;
} {
    if (third === undefined || third === null) {
        return {
            timeoutMs: INTEGRATION_HTTP_TIMEOUT_MS,
            bypassHostRemap: false
        };
    }
    if (typeof third === "number") {
        return {
            timeoutMs: third,
            bypassHostRemap: false
        };
    }
    return {
        timeoutMs: third.timeoutMs ?? INTEGRATION_HTTP_TIMEOUT_MS,
        bypassHostRemap: Boolean(third.bypassHostRemap)
    };
}
export async function integrationFetch(url: string, init: RequestInit = {}, third?: number | IntegrationFetchOptions): Promise<Response> {
    const { timeoutMs, bypassHostRemap } = resolveIntegrationFetchOptions(third);
    const skipRemap = bypassHostRemap || probeHostIsRemapSource(url, env.INTEGRATIONS_PROBE_HOST_REMAP);
    const resolvedUrl = skipRemap ? url : remapIntegrationProbeHost(url, env.INTEGRATIONS_PROBE_HOST_REMAP);
    const ms = timeoutMs;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(new Error(`Integration request timed out after ${ms}ms`)), ms);
    const parent = init.signal;
    const onParentAbort = () => {
        controller.abort(parent?.reason ?? new Error("Aborted"));
    };
    if (parent) {
        if (parent.aborted) {
            onParentAbort();
        }
        else {
            parent.addEventListener("abort", onParentAbort, { once: true });
        }
    }
    try {
        const skipTls = env.INTEGRATIONS_TLS_SKIP_VERIFY === "true" || env.KUBE_TLS_SKIP_VERIFY === "true";
        if (skipTls) {
            return await undiciFetch(resolvedUrl, {
                ...init,
                signal: controller.signal,
                dispatcher: insecureAgent
            } as Parameters<typeof undiciFetch>[1]) as unknown as Response;
        }
        return await fetch(resolvedUrl, { ...init, signal: controller.signal });
    }
    finally {
        clearTimeout(timer);
        if (parent) {
            parent.removeEventListener("abort", onParentAbort);
        }
    }
}

// --- format-fetch-error ---
export function formatFetchErrorChain(error: unknown): string {
    if (!(error instanceof Error)) {
        return String(error);
    }
    const parts: string[] = [];
    let cur: unknown = error;
    for (let depth = 0; depth < 8 && cur; depth++) {
        if (cur instanceof Error) {
            const code = (cur as NodeJS.ErrnoException).code;
            const chunk = code && !cur.message.includes(String(code)) ? `${cur.message} (${code})` : cur.message;
            if (chunk) {
                parts.push(chunk);
            }
            cur = "cause" in cur ? cur.cause : undefined;
        }
        else if (typeof cur === "object" && cur !== null && "message" in cur) {
            parts.push(String((cur as {
                message: unknown;
            }).message));
            break;
        }
        else {
            break;
        }
    }
    return parts.join(" \u2014 ");
}

// --- ttl-cache ---
type CacheEntry<T> = {
    value: T;
    expiresAt: number;
};

export class TtlCache<T> {
    private readonly store = new Map<string, CacheEntry<T>>();

    constructor(private readonly defaultTtlMs: number) {}

    get(key: string): T | undefined {
        const row = this.store.get(key);
        if (!row) {
            return undefined;
        }
        if (Date.now() >= row.expiresAt) {
            this.store.delete(key);
            return undefined;
        }
        return row.value;
    }

    set(key: string, value: T, ttlMs?: number): void {
        this.store.set(key, {
            value,
            expiresAt: Date.now() + (ttlMs ?? this.defaultTtlMs)
        });
    }

    clear(): void {
        this.store.clear();
    }

    delete(key: string): void {
        this.store.delete(key);
    }

    async getOrSet(key: string, factory: () => Promise<T>, ttlMs?: number): Promise<T> {
        const cached = this.get(key);
        if (cached !== undefined) {
            return cached;
        }
        const value = await factory();
        this.set(key, value, ttlMs);
        return value;
    }
}

// --- rate-limit ---
type RateLimitOptions = {
    keyPrefix: string;
    windowMs: number;
    maxRequests: number;
    message?: string;
};
type RateLimitRecord = {
    count: number;
    resetAt: number;
};
const bucket = new Map<string, RateLimitRecord>();
function getClientAddress(request: Request) {
    const forwardedFor = request.headers.get("x-forwarded-for") || "";
    const firstForwarded = forwardedFor.split(",")[0]?.trim();
    const realIp = request.headers.get("x-real-ip")?.trim();
    return firstForwarded || realIp || "unknown";
}
export function enforceRateLimit(request: Request, options: RateLimitOptions) {
    const now = Date.now();
    const key = `${options.keyPrefix}:${getClientAddress(request)}`;
    const existing = bucket.get(key);
    if (!existing || existing.resetAt <= now) {
        bucket.set(key, {
            count: 1,
            resetAt: now + options.windowMs
        });
        return;
    }
    if (existing.count >= options.maxRequests) {
        throw new ApiError(429, options.message || "Too many requests. Please retry later.");
    }
    existing.count += 1;
    bucket.set(key, existing);
}

export function remapIntegrationProbeHost(url: string, remapSpec: string): string {
    let out = url;
    for (const part of remapSpec.split(/[,;]/)) {
        const spec = part.trim();
        if (!spec) {
            continue;
        }
        const eq = spec.indexOf("=");
        if (eq <= 0) {
            continue;
        }
        const fromHost = spec.slice(0, eq).trim().toLowerCase();
        const toHost = spec.slice(eq + 1).trim();
        if (!fromHost || !toHost) {
            continue;
        }
        try {
            const u = new URL(out);
            if (u.hostname.toLowerCase() === fromHost) {
                u.hostname = toHost;
                out = u.toString();
            }
        }
        catch {
            continue;
        }
    }
    return out;
}

export function probeHostIsRemapSource(url: string, remapSpec: string): boolean {
    const raw = remapSpec.trim();
    if (!raw) {
        return false;
    }
    let host: string;
    try {
        host = new URL(url).hostname.toLowerCase();
    }
    catch {
        return false;
    }
    for (const part of raw.split(/[,;]/)) {
        const spec = part.trim();
        const eq = spec.indexOf("=");
        if (eq <= 0) {
            continue;
        }
        const fromHost = spec.slice(0, eq).trim().toLowerCase();
        if (fromHost && host === fromHost) {
            return true;
        }
    }
    return false;
}
