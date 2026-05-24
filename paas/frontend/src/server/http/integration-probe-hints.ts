export function appendUnreachableProbeHint(itemId: string | undefined, _probedUrl: string, message: string): string {
    const m = message.trim();
    if (!/ECONNREFUSED|ENOTFOUND|ETIMEDOUT|fetch failed|other side closed/i.test(m)) {
        return message;
    }
    if (itemId === "trivy-policy") {
        return `${m} — use NodePort :30954 or harbor-trivy:8080; run: bash paas/scripts/fix-integrations-lab.sh`;
    }
    if (itemId === "grafana") {
        return `${m} — use kube-prometheus-stack-grafana:80 in-cluster, NodePort :32383 in browser; run fix-integrations-lab.sh`;
    }
    return `${m} — run: bash paas/scripts/fix-integrations-lab.sh`;
}
