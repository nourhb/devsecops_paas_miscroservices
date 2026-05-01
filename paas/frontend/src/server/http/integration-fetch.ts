import { INTEGRATION_HTTP_TIMEOUT_MS } from "@/server/constants/deploy";
import { Agent, fetch as undiciFetch } from "undici";
import { env } from "@/server/config/env";
const insecureAgent = new Agent({
    connect: {
        rejectUnauthorized: false
    }
});
export async function integrationFetch(url: string, init: RequestInit = {}, timeoutMs: number = INTEGRATION_HTTP_TIMEOUT_MS): Promise<Response> {
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
        if (env.INTEGRATIONS_TLS_SKIP_VERIFY === "true") {
            return await undiciFetch(url, {
                ...init,
                signal: controller.signal,
                dispatcher: insecureAgent
            } as Parameters<typeof undiciFetch>[1]) as unknown as Response;
        }
        return await fetch(url, { ...init, signal: controller.signal });
    }
    finally {
        clearTimeout(timer);
        if (parent) {
            parent.removeEventListener("abort", onParentAbort);
        }
    }
}
