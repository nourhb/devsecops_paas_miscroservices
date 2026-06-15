import { env } from "@/server/config/env";
import { buildDeployImageRepository, buildDeployImageRepositoryForClusterPull, deployImageRepositoryForClusterPull, harborClusterPullImageRef, sanitizeDeployImageName } from "@/server/deploy/deploy-image";
import { gitopsChartShortNameForProject } from "@/server/gitops/gitops-paths";

export type DeploymentStrategy = "Rolling" | "BlueGreen";
export type BlueGreenSlot = "blue" | "green";

export function resolveDeploymentStrategy(doc?: Record<string, unknown> | null): DeploymentStrategy {
    const fromDoc = doc?.deploymentStrategy;
    if (typeof fromDoc === "string" && fromDoc.toLowerCase() === "bluegreen") {
        return "BlueGreen";
    }
    const fromEnv = (env.PAAS_DEPLOYMENT_STRATEGY || "Rolling").trim();
    return fromEnv.toLowerCase() === "bluegreen" ? "BlueGreen" : "Rolling";
}

export function inactiveSlot(active: BlueGreenSlot): BlueGreenSlot {
    return active === "blue" ? "green" : "blue";
}

export function helmReleaseName(projectName: string): string {
    const prefix = env.ARGOCD_APP_PREFIX.trim() || "paas";
    return `${prefix}-${sanitizeDeployImageName(projectName)}`;
}

export function helmChartNameCandidates(projectName: string): string[] {
    const slug = sanitizeDeployImageName(projectName);
    const dir = gitopsChartShortNameForProject(projectName);
    return [...new Set(["simple-app", dir, slug].filter(Boolean))];
}

export function blueGreenDeploymentNameCandidates(projectName: string, slot: BlueGreenSlot): string[] {
    const release = helmReleaseName(projectName);
    return helmChartNameCandidates(projectName).map((chart) => `${release}-${chart}-${slot}`);
}

export function rollingDeploymentNameCandidates(projectName: string): string[] {
    const release = helmReleaseName(projectName);
    return helmChartNameCandidates(projectName).map((chart) => `${release}-${chart}`);
}

function slotImageBlock(doc: Record<string, unknown>, slot: BlueGreenSlot): Record<string, unknown> {
    const key = slot;
    const block = doc[key];
    if (block && typeof block === "object" && block !== null) {
        return block as Record<string, unknown>;
    }
    const created: Record<string, unknown> = { image: {} };
    doc[key] = created;
    return created;
}

function splitImageRef(ref: string): { repository: string; tag: string; digest: string } {
    const digestSeparator = ref.indexOf("@sha256:");
    if (digestSeparator > 0) {
        return {
            repository: ref.slice(0, digestSeparator),
            tag: "",
            digest: ref.slice(digestSeparator + 1)
        };
    }
    const lastColon = ref.lastIndexOf(":");
    if (lastColon > 0 && lastColon < ref.length - 1 && !ref.slice(lastColon).includes("/")) {
        return { repository: ref.slice(0, lastColon), tag: ref.slice(lastColon + 1), digest: "" };
    }
    return { repository: ref, tag: "", digest: "" };
}

export function ensureBlueGreenValuesStructure(
    doc: Record<string, unknown>,
    projectName: string,
    imageTag: string
): { activeSlot: BlueGreenSlot; inactive: BlueGreenSlot } {
    doc.deploymentStrategy = "BlueGreen";
    const active: BlueGreenSlot = doc.activeSlot === "green" ? "green" : "blue";
    const inactive = inactiveSlot(active);
    const normalizedTag = harborClusterPullImageRef(imageTag);
    const { repository, tag, digest } = splitImageRef(normalizedTag);
    const repo = repository || buildDeployImageRepositoryForClusterPull(projectName);

    const legacy = doc.image && typeof doc.image === "object" && doc.image !== null
        ? (doc.image as Record<string, unknown>)
        : null;
    for (const slot of ["blue", "green"] as const) {
        const block = slotImageBlock(doc, slot);
        const img = block.image && typeof block.image === "object" && block.image !== null
            ? (block.image as Record<string, unknown>)
            : {};
        block.image = img;
        if (!img.repository) {
            img.repository = (legacy?.repository as string) || repo;
        }
        if (slot === inactive && tag) {
            img.tag = tag;
            img.digest = digest;
        }
        else if (slot === active) {
            if (!img.tag && !img.digest && legacy) {
                img.tag = legacy.tag ?? "";
                img.digest = legacy.digest ?? "";
                if (!img.repository && legacy.repository) {
                    img.repository = legacy.repository;
                }
            }
            else if (!img.tag && !img.digest) {
                img.tag = tag || "latest";
            }
        }
    }

    doc.activeSlot = active;
    doc.image = {
        repository: (slotImageBlock(doc, active).image as Record<string, unknown>).repository ?? repo,
        tag: ((slotImageBlock(doc, active).image as Record<string, unknown>).tag as string) ?? "",
        digest: ((slotImageBlock(doc, active).image as Record<string, unknown>).digest as string) ?? "",
        pullPolicy: "IfNotPresent"
    };

    return { activeSlot: active, inactive };
}

export function applyBlueGreenInactiveImage(
    doc: Record<string, unknown>,
    projectName: string,
    imageTag: string
): { activeSlot: BlueGreenSlot; inactive: BlueGreenSlot } {
    const normalizedTag = harborClusterPullImageRef(imageTag);
    const { activeSlot, inactive } = ensureBlueGreenValuesStructure(doc, projectName, normalizedTag);
    const { repository, tag, digest } = splitImageRef(normalizedTag);
    const block = slotImageBlock(doc, inactive);
    const img = block.image as Record<string, unknown>;
    img.repository = repository || buildDeployImageRepositoryForClusterPull(projectName);
    img.tag = tag;
    img.digest = digest;
    return { activeSlot, inactive };
}

export function flipBlueGreenActiveSlot(doc: Record<string, unknown>): BlueGreenSlot {
    const current: BlueGreenSlot = doc.activeSlot === "green" ? "green" : "blue";
    const next = inactiveSlot(current);
    doc.activeSlot = next;
    doc.deploymentStrategy = "BlueGreen";
    const block = slotImageBlock(doc, next);
    const img = block.image as Record<string, unknown>;
    doc.image = {
        repository: img.repository,
        tag: img.tag ?? "",
        digest: img.digest ?? "",
        pullPolicy: "IfNotPresent"
    };
    return next;
}

export function blueGreenDeploymentName(projectName: string, slot: BlueGreenSlot): string {
    const candidates = blueGreenDeploymentNameCandidates(projectName, slot);
    const release = helmReleaseName(projectName);
    const legacy = `${release}-simple-app-${slot}`;
    if (candidates.includes(legacy)) {
        return legacy;
    }
    return candidates[0];
}

export function applyRollingImage(doc: Record<string, unknown>, projectName: string, imageTag: string): void {
    doc.deploymentStrategy = "Rolling";
    delete doc.activeSlot;
    delete doc.blue;
    delete doc.green;
    const normalizedTag = harborClusterPullImageRef(imageTag);
    const { repository, tag, digest } = splitImageRef(normalizedTag);
    doc.image = {
        repository: deployImageRepositoryForClusterPull(repository || buildDeployImageRepository(projectName)),
        tag,
        digest,
        pullPolicy: "IfNotPresent"
    };
}
