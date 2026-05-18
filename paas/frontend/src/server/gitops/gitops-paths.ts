import { env } from "@/server/config/env";

function applyProjectPathPattern(pattern: string, projectName: string): string {
    return pattern.replace(/\{\{projectName\}\}/gi, projectName).replace(/\{\{project\}\}/gi, projectName);
}

export function gitopsValuesPathForProject(projectName: string): string {
    return applyProjectPathPattern(env.GITOPS_VALUES_PATH_PATTERN, projectName);
}

/** Helm chart directory in the GitOps repo (parent of values.yaml unless GITOPS_CHART_PATH_PATTERN is set). */
export function gitopsHelmChartPathForProject(projectName: string): string {
    const explicit = env.GITOPS_CHART_PATH_PATTERN.trim();
    if (explicit) {
        return applyProjectPathPattern(explicit, projectName);
    }
    const valuesPath = applyProjectPathPattern(env.GITOPS_VALUES_PATH_PATTERN, projectName).replace(/\\/g, "/");
    if (valuesPath.endsWith("/values.yaml")) {
        return valuesPath.slice(0, -"/values.yaml".length);
    }
    if (valuesPath.endsWith("values.yaml")) {
        const slash = valuesPath.lastIndexOf("/");
        return slash > 0 ? valuesPath.slice(0, slash) : `apps/${projectName}`;
    }
    return `apps/${projectName}`;
}
