import { INTEGRATION_HTTP_TIMEOUT_MS } from "@/server/constants/deploy";
import { env } from "@/server/config/env";
import { probeHostIsRemapSource, remapIntegrationProbeHost } from "@/server/http/integration-probe-host";
import { Agent, fetch as undiciFetch } from "undici";
const insecureAgent = new Agent({
    connect: {
        rejectUnauthorized: false
    }
});
export type IntegrationFetchOptions = {
    timeoutMs?: number;
    /** When true, force-skip INTEGRATIONS_PROBE_HOST_REMAP (also skipped automatically when the URL host matches a remap rule’s left-hand side). */
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
    const skipRemap =
        bypassHostRemap || probeHostIsRemapSource(url, env.INTEGRATIONS_PROBE_HOST_REMAP);
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
        const skipTls =
            env.INTEGRATIONS_TLS_SKIP_VERIFY === "true" || env.KUBE_TLS_SKIP_VERIFY === "true";
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
