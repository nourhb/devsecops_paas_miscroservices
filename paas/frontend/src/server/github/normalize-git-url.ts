export function normalizeGitUrl(input: string): string {
    const raw = String(input || "").trim();
    if (!raw) {
        return "";
    }
    const scpLike = raw.match(/^git@([^:]+):(.+)$/i);
    if (scpLike) {
        const host = scpLike[1].toLowerCase();
        const path = scpLike[2].replace(/\.git$/i, "");
        return `https://${host}/${path}`.toLowerCase();
    }
    try {
        const url = new URL(raw);
        const host = url.host.toLowerCase();
        const path = url.pathname.replace(/\/+$/, "").replace(/\.git$/i, "");
        return `https://${host}${path}`.toLowerCase();
    }
    catch {
        return raw.replace(/\/+$/, "").replace(/\.git$/i, "").toLowerCase();
    }
}
