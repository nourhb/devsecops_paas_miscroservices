/**
 * Rewrites URL hostnames for server-side integration probes (Platform hub, Jenkins hooks, etc.).
 * Use when NEXT_PUBLIC_* / service URLs point at a VM IP that is not reachable from the Next.js
 * container (e.g. set INTEGRATIONS_PROBE_HOST_REMAP=192.168.56.129=host.docker.internal under Docker Compose).
 *
 * Multiple rules: comma- or semicolon-separated `oldHost=newHost` (applied left to right).
 */
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
