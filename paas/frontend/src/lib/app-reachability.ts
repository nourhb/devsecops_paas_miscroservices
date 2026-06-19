export function shouldSkipAppReachabilityProbe(url: string | null | undefined): boolean {
    const raw = (url ?? "").trim();
    if (!raw) {
        return true;
    }
    try {
        const u = new URL(raw);
        const h = u.hostname.toLowerCase();
        return h === "localhost" || h === "127.0.0.1" || h === "::1" || h.endsWith(".localhost")
            || (h.endsWith(".local") && !h.endsWith(".nip.io"));
    }
    catch {
        return false;
    }
}
