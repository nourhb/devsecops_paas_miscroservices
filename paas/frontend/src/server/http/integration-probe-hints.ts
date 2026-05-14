/**
 * Appends short, actionable hints when integration HTTP probes fail with typical lab misconfigurations.
 */
export function appendUnreachableProbeHint(itemId: string | undefined, probedUrl: string, message: string): string {
    const m = message.trim();
    if (!/ECONNREFUSED|ENOTFOUND|ETIMEDOUT|fetch failed/i.test(m)) {
        return message;
    }
    const u = probedUrl;
    const tips: string[] = [];
    if (/:4954(\/|$|\?|:)/.test(u)) {
        tips.push("Trivy is reached on the Service NodePort (often …:30954), not in-cluster port 4954 — `kubectl get svc -n security`.");
    }
    if (/:31504(\/|$|\?|:)/.test(u)) {
        tips.push("Many k3s+Traefik labs use HTTP NodePort 30659 (not 31504). Update NEXT_PUBLIC_INGRESS_NGINX_URL or INGRESS_NGINX_PROBE_URL (see docker-compose.env.example).");
    }
    if (itemId === "trivy-policy" && /:30954(\/|$|\?|:)/.test(u)) {
        tips.push("Port 30954 is often correct; refusal from this host usually means the Next.js process cannot reach the node IP (e.g. Docker on a laptop) — set INTEGRATIONS_PROBE_HOST_REMAP=192.168.56.129=host.docker.internal, or run the app on the same LAN as the cluster.");
    }
    if (/:30092(\/|$|\?|:)/.test(u)) {
        tips.push("Harbor aggregate NodePort is often 30002 (not 30092) — `kubectl get svc -n harbor harbor`. Align HARBOR_BASE_URL.");
    }
    if (/:30086(\/|$|\?|:)/.test(u)) {
        tips.push("SonarQube is often on NodePort 30900 — `kubectl get svc -n sonarqube`.");
    }
    if (/:30084(\/|$|\?|:)/.test(u)) {
        tips.push("After kube-prometheus-stack upgrades, Alertmanager NodePort may differ (e.g. …:30772) — `kubectl get svc -n monitoring | grep -i alert`.");
    }
    if (itemId === "pushgateway") {
        tips.push("Helm pushgateway is often ClusterIP-only (no NodePort) — omit NEXT_PUBLIC_PUSHGATEWAY_URL until `kubectl get svc -n monitoring` shows a reachable URL, or expose the service.");
    }
    if (itemId === "argocd") {
        tips.push("Match ARGOCD_BASE_URL to `kubectl get svc -n argocd argocd-server` NodePorts, set ARGOCD_AUTH_TOKEN, and ARGOCD_TLS_SKIP_VERIFY / KUBE_TLS_SKIP_VERIFY for lab TLS.");
    }
    if (itemId === "opa-server") {
        tips.push("Nothing is listening on OPA_EVAL_URL from this server — deploy OPA, port-forward, or fix the URL/port.");
    }
    if (tips.length === 0) {
        tips.push("Confirm NodePorts with kubectl, pods Running, and from Docker try INTEGRATIONS_PROBE_HOST_REMAP=192.168.56.129=host.docker.internal when the node IP is unreachable from the container.");
    }
    return `${message} — ${tips.join(" ")}`;
}
