export function appendUnreachableProbeHint(_itemId: string | undefined, _probedUrl: string, message: string): string {
    const m = message.trim();
    if (!/ECONNREFUSED|ENOTFOUND|ETIMEDOUT|fetch failed/i.test(m)) {
        return message;
    }
    return `${m} — not reachable from the PaaS pod (service down, wrong port, or set *_PROBE_URL to in-cluster DNS — run fix-integrations-lab.sh on the VM).`;
}
