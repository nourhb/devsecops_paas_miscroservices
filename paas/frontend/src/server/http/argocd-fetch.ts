import { Agent, fetch as undiciFetch } from "undici";
import { env } from "@/server/config/env";
import { INTEGRATION_HTTP_TIMEOUT_MS } from "@/server/constants/deploy";
const argoInsecureAgent = new Agent({
    connect: {
        rejectUnauthorized: false
    }
});
function withTimeoutSignal(init: RequestInit, controller: AbortController): RequestInit {
    return { ...init, signal: controller.signal };
}
export async function argocdIntegrationFetch(url: string, init: RequestInit = {}): Promise<Response> {
    const ms = INTEGRATION_HTTP_TIMEOUT_MS;
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
    const skipTls = env.ARGOCD_TLS_SKIP_VERIFY === "true";
    try {
        const nextInit = withTimeoutSignal(init, controller);
        if (skipTls) {
            const res = await undiciFetch(url, {
                ...nextInit,
                dispatcher: argoInsecureAgent
            } as Parameters<typeof undiciFetch>[1]);
            return res as unknown as Response;
        }
        return await fetch(url, nextInit);
    }
    finally {
        clearTimeout(timer);
        if (parent) {
            parent.removeEventListener("abort", onParentAbort);
        }
    }
}
