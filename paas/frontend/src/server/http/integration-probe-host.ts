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
