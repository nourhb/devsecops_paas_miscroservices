import { realValueOrEmpty } from "@/server/config/real-values";

function trimUrl(value: string | undefined | null): string {
    return realValueOrEmpty(value).replace(/\/+$/, "");
}

/** True when the URL is only resolvable inside the Kubernetes cluster. */
export function isInClusterOnlyUrl(value: string | undefined | null): boolean {
    const raw = trimUrl(value);
    if (!raw) {
        return false;
    }
    try {
        const host = new URL(raw).hostname.toLowerCase();
        if (host.endsWith(".svc") || host.endsWith(".svc.cluster.local") || host.includes(".cluster.local")) {
            return true;
        }
        if (host === "kubernetes" || host === "kubernetes.default" || host === "kubernetes.default.svc") {
            return true;
        }
        return false;
    }
    catch {
        return false;
    }
}

/** Pick the first URL suitable for browser "Open tool" links (never in-cluster-only). */
export function browserToolHref(...candidates: (string | undefined | null)[]): string | null {
    for (const candidate of candidates) {
        const url = trimUrl(candidate);
        if (!url || isInClusterOnlyUrl(url)) {
            continue;
        }
        return url;
    }
    return null;
}
