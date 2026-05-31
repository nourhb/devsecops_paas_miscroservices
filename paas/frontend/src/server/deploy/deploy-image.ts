import { env } from "@/server/config/env";
import { IntegrationError } from "@/server/http/errors";

export function sanitizeDeployImageName(projectName: string): string {
    return projectName
        .toLowerCase()
        .replace(/[^a-z0-9._-]/g, "-")
        .replace(/-+/g, "-")
        .replace(/^-|-$/g, "") || "app";
}

/** OCI/Docker references must be lowercase in the repository path. */
export function normalizeOciImageReference(imageRef: string): string {
    return imageRef.trim().toLowerCase();
}

export function buildDeployImageRepository(projectName: string): string {
    const safeName = sanitizeDeployImageName(projectName);
    const template = env.DEPLOY_IMAGE_NAME_TEMPLATE.trim();
    if (template) {
        return normalizeOciImageReference(template
            .replace(/\{\{projectName\}\}/gi, safeName)
            .replace(/\{\{harborProject\}\}/gi, env.HARBOR_PROJECT.toLowerCase()));
    }
    const harborHost = env.HARBOR_BASE_URL.replace(/^https?:\/\//i, "").replace(/\/$/, "").split("/")[0];
    if (harborHost) {
        return normalizeOciImageReference(`${harborHost}/${env.HARBOR_PROJECT.toLowerCase()}/${safeName}`);
    }
    const dockerNamespace = env.DOCKERHUB_NAMESPACE.trim() || env.DOCKERHUB_USERNAME.trim();
    if (dockerNamespace) {
        return normalizeOciImageReference(`${dockerNamespace.toLowerCase()}/${safeName}`);
    }
    throw new IntegrationError("Configure one real image repository source: DEPLOY_IMAGE_NAME_TEMPLATE, or DOCKERHUB_NAMESPACE/DOCKERHUB_USERNAME, or HARBOR_BASE_URL.");
}

export function buildDeployImageTag(projectName: string, tag: string | number): string {
    return normalizeOciImageReference(`${buildDeployImageRepository(projectName)}:${tag}`);
}
