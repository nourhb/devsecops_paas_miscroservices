import { env } from "@/server/config/env";
import { sanitizeDeployImageName } from "@/server/deploy/deploy-image";

function gitopsProjectSlug(projectName: string): string {
    return sanitizeDeployImageName(projectName);
}
function applyProjectPathPattern(pattern: string, projectName: string): string {
    const slug = gitopsProjectSlug(projectName);
    return pattern.replace(/\{\{projectName\}\}/gi, slug).replace(/\{\{project\}\}/gi, slug);
}
export function gitopsValuesPathForProject(projectName: string): string {
    return applyProjectPathPattern(env.GITOPS_VALUES_PATH_PATTERN, projectName);
}
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
        return slash > 0 ? valuesPath.slice(0, slash) : `apps/${gitopsProjectSlug(projectName)}`;
    }
    return `apps/${gitopsProjectSlug(projectName)}`;
}
