import { env } from "@/server/config/env";
import { coerceHarborRegistryHostForCosign, normalizeHarborImageRef } from "@/server/deploy/harbor-registry-host";
import { IntegrationError } from "@/server/http/errors";

export function sanitizeDeployImageName(projectName: string): string {
    return projectName
        .toLowerCase()
        .replace(/[^a-z0-9._-]/g, "-")
        .replace(/-+/g, "-")
        .replace(/^-|-$/g, "") || "app";
}

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
    const harborHost = coerceHarborRegistryHostForCosign(
        env.HARBOR_REGISTRY || env.HARBOR_BASE_URL.replace(/^https?:\/\//, "").replace(/\/$/, "").split("/")[0]
    );
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

export function normalizeDeployImageRepositoryRef(imageRef: string): string {
    const trimmed = imageRef.trim().toLowerCase();
    const digestAt = trimmed.indexOf("@sha256:");
    const withoutDigest = digestAt > 0 ? trimmed.slice(0, digestAt) : trimmed;
    const slash = withoutDigest.lastIndexOf("/");
    const lastColon = withoutDigest.lastIndexOf(":");
    if (lastColon > slash && lastColon < withoutDigest.length - 1) {
        return withoutDigest.slice(0, lastColon);
    }
    return withoutDigest;
}

export function deployImageRepositoryMatchesProject(imageRef: string, projectName: string): boolean {
    const expected = buildDeployImageRepository(projectName).toLowerCase();
    const actual = normalizeDeployImageRepositoryRef(imageRef);
    if (actual === expected) {
        return true;
    }
    const coercedActual = normalizeDeployImageRepositoryRef(normalizeHarborImageRef(imageRef));
    if (coercedActual === expected) {
        return true;
    }
    const short = sanitizeDeployImageName(projectName);
    if (actual === short) {
        return true;
    }
    if (actual.endsWith(`/${short}`)) {
        return true;
    }
    return false;
}
