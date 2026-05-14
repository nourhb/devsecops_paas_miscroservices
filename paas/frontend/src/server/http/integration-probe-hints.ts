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
        if (/172\.17\.0\.1/.test(u)) {
            tips.push("Probe hit Docker bridge gateway 172.17.0.1 (host.docker.internal / host-gateway): NodePorts on a **separate** k3s VM are not listening on the Docker host. Remove INTEGRATIONS_PROBE_HOST_REMAP for that VM IP, or set TRIVY_PROBE_URL to a base URL this container can reach (often the same VM IP as kubectl from your workstation).");
        }
        else {
            tips.push("Port 30954 is often correct; refusal usually means this process cannot reach the node IP from Docker. If INTEGRATIONS_PROBE_HOST_REMAP rewrites this URL’s host to the Docker bridge, the hub skips that remap when the host matches the remap source (VM IP), or set TRIVY_PROBE_URL (always skips remap).");
        }
    }
    if ((itemId === "pushgateway" || itemId === "jenkins") && /172\.17\.0\.1/.test(u)) {
        tips.push("Same as Trivy: 172.17.0.1 is the Docker host, not your k3s VM — remove remap for VM-only labs or set PUSHGATEWAY_PROBE_URL / JENKINS_PROBE_URL to a reachable base URL.");
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
        if (/172\.17\.0\.1/.test(u)) {
            tips.push("172.17.0.1 is Docker host-gateway; if k3s runs on another VM, remap to host.docker.internal is wrong — use direct VM IP from this container or dedicated *_PROBE_URL vars (see docker-compose.env.example).");
        }
        else {
            tips.push("Confirm NodePorts with kubectl and pods Running; from Docker, INTEGRATIONS_PROBE_HOST_REMAP or *_PROBE_URL can fix reachability when the VM IP differs from what the server can route to.");
        }
    }
    return `${message} — ${tips.join(" ")}`;
}
