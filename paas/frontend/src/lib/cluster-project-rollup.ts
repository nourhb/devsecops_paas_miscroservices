/** Roll up coarse workload metrics from PaaS project records when Kubernetes API is unavailable. */
export function rollUpClusterFromProjects(projects: Array<{
    lastDeploymentStatus: string;
    podStatus: string;
    url: string | null;
}>): {
    runningPods: number;
    unhealthyPods: number;
    services: number;
    deployments: number;
    healthyDeployments: number;
} {
    const runningPods = projects.filter((p) => {
        const d = (p.lastDeploymentStatus || "").toUpperCase();
        if (d === "DEPLOYED" || d === "SUCCESS") {
            return true;
        }
        return /\d+\s*running/i.test(p.podStatus || "") || /\brunning\b/i.test(p.podStatus || "");
    }).length;
    const unhealthyPods = projects.filter((p) => {
        if ((p.lastDeploymentStatus || "").toUpperCase() === "FAILED") {
            return true;
        }
        const ps = (p.podStatus || "").toUpperCase();
        return ps.includes("FAIL") || ps.includes("ERROR") || ps.includes("CRASH") || ps === "UNKNOWN";
    }).length;
    const healthyDeployments = projects.filter((p) => {
        const d = (p.lastDeploymentStatus || "").toUpperCase();
        return d === "DEPLOYED" || d === "SUCCESS";
    }).length;
    return {
        runningPods,
        unhealthyPods,
        services: projects.filter((p) => Boolean(p.url?.trim())).length,
        deployments: projects.length,
        healthyDeployments
    };
}
