/**
 * Rewrites URL hostnames for server-side integration probes (Platform hub, Jenkins hooks, etc.).
 * Use when NEXT_PUBLIC_* / service URLs point at a VM IP that is not reachable from the Next.js
 * container (e.g. set INTEGRATIONS_PROBE_HOST_REMAP=192.168.56.129=host.docker.internal under Docker Compose).
 */
export function remapIntegrationProbeHost(url: string, remapSpec: string): string {
    const spec = remapSpec.trim();
    if (!spec) {
        return url;
    }
    const eq = spec.indexOf("=");
    if (eq <= 0) {
        return url;
    }
    const fromHost = spec.slice(0, eq).trim().toLowerCase();
    const toHost = spec.slice(eq + 1).trim();
    if (!fromHost || !toHost) {
        return url;
    }
    try {
        const u = new URL(url);
        if (u.hostname.toLowerCase() === fromHost) {
            u.hostname = toHost;
            return u.toString();
        }
    }
    catch {
    }
    return url;
}
