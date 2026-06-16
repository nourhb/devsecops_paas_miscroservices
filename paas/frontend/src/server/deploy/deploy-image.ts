import { env } from "@/server/config/env";
import { coerceHarborRegistryHostForCosign, harborIpRegistryHostFromNipio, normalizeHarborImageRef } from "@/server/deploy/harbor-registry-host";
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

export function canonicalDeployImageRepository(imageRef: string): string {
    return normalizeDeployImageRepositoryRef(normalizeHarborImageRef(imageRef.trim().toLowerCase()));
}

export function buildDeployImageRepository(projectName: string): string {
    const safeName = sanitizeDeployImageName(projectName);
    const template = env.DEPLOY_IMAGE_NAME_TEMPLATE.trim();
    if (template) {
        const fromTemplate = template
            .replace(/\{\{projectName\}\}/gi, safeName)
            .replace(/\{\{harborProject\}\}/gi, env.HARBOR_PROJECT.toLowerCase());
        return normalizeOciImageReference(normalizeHarborImageRef(fromTemplate));
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

export function deployImageRepositoryForClusterPull(imageRef: string): string {
    const repo = normalizeDeployImageRepositoryRef(imageRef);
    const slash = repo.indexOf("/");
    if (slash < 0) {
        return repo;
    }
    const host = repo.slice(0, slash);
    const path = repo.slice(slash);
    return `${harborIpRegistryHostFromNipio(host)}${path}`.toLowerCase();
}

export function harborClusterPullImageRef(imageRef: string): string {
    const ref = imageRef.trim();
    if (!ref) {
        return ref;
    }
    const digestAt = ref.indexOf("@sha256:");
    if (digestAt > 0) {
        const repo = ref.slice(0, digestAt);
        const digest = ref.slice(digestAt);
        return `${deployImageRepositoryForClusterPull(repo)}${digest}`.toLowerCase();
    }
    const slash = ref.indexOf("/");
    const lastColon = ref.lastIndexOf(":");
    if (slash > 0 && lastColon > slash && lastColon < ref.length - 1) {
        const repo = ref.slice(0, lastColon);
        const tag = ref.slice(lastColon);
        return `${deployImageRepositoryForClusterPull(repo)}${tag}`.toLowerCase();
    }
    return deployImageRepositoryForClusterPull(ref);
}

export function buildDeployImageRepositoryForClusterPull(projectName: string): string {
    return deployImageRepositoryForClusterPull(buildDeployImageRepository(projectName));
}

export function harborImageRepoPath(imageRef: string): string {
    const repo = normalizeDeployImageRepositoryRef(imageRef).toLowerCase();
    const slash = repo.indexOf("/");
    return slash >= 0 ? repo.slice(slash + 1) : repo;
}

export function deployImageRepositoryMatchesProject(imageRef: string, projectName: string): boolean {
    const expected = buildDeployImageRepository(projectName);
    const actual = imageRef;
    if (canonicalDeployImageRepository(actual) === canonicalDeployImageRepository(expected)) {
        return true;
    }
    if (deployImageRepositoryForClusterPull(actual) === deployImageRepositoryForClusterPull(expected)) {
        return true;
    }
    if (harborImageRepoPath(actual) === harborImageRepoPath(expected)) {
        return true;
    }
    const short = sanitizeDeployImageName(projectName);
    const bareActual = normalizeDeployImageRepositoryRef(imageRef).toLowerCase();
    if (bareActual === short) {
        return true;
    }
    if (bareActual.endsWith(`/${short}`)) {
        return true;
    }
    return false;
}
