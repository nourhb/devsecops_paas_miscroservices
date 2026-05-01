import { env } from "@/server/config/env";
import { IntegrationError } from "@/server/http/errors";
function sanitizeProjectName(projectName: string): string {
    return projectName
        .toLowerCase()
        .replace(/[^a-z0-9._-]/g, "-")
        .replace(/-+/g, "-")
        .replace(/^-|-$/g, "") || "app";
}
export function buildDeployImageRepository(projectName: string): string {
    const template = env.DEPLOY_IMAGE_NAME_TEMPLATE.trim();
    if (template) {
        return template
            .replace(/\{\{projectName\}\}/gi, projectName)
            .replace(/\{\{harborProject\}\}/gi, env.HARBOR_PROJECT);
    }
    const safeName = sanitizeProjectName(projectName);
    const dockerNamespace = env.DOCKERHUB_NAMESPACE.trim() || env.DOCKERHUB_USERNAME.trim();
    if (dockerNamespace) {
        return `${dockerNamespace}/${safeName}`;
    }
    const host = env.HARBOR_BASE_URL.replace(/^https?:\/\//i, "").replace(/\/$/, "");
    if (host) {
        return `${host}/${env.HARBOR_PROJECT}/${safeName}`;
    }
    throw new IntegrationError("Configure one real image repository source: DEPLOY_IMAGE_NAME_TEMPLATE, or DOCKERHUB_NAMESPACE/DOCKERHUB_USERNAME, or HARBOR_BASE_URL.");
}
