import { env } from "@/server/config/env";
import { buildDeployImageRepository } from "@/server/deploy/deploy-image";

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

/** Ensure values.yaml has blue/green structure (Rolling projects stay on `image` only). */
export function ensureBlueGreenValuesStructure(
    doc: Record<string, unknown>,
    projectName: string,
    imageTag: string
): { activeSlot: BlueGreenSlot; inactive: BlueGreenSlot } {
    doc.deploymentStrategy = "BlueGreen";
    const active: BlueGreenSlot = doc.activeSlot === "green" ? "green" : "blue";
    const inactive = inactiveSlot(active);
    const { repository, tag, digest } = splitImageRef(imageTag);
    const repo = repository || buildDeployImageRepository(projectName);

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
    // Keep legacy `image` in sync with active slot for scripts that only read .Values.image
    const activeBlock = slotImageBlock(doc, active);
    const activeImg = activeBlock.image as Record<string, unknown>;
    doc.image = {
        repository: activeImg.repository ?? repo,
        tag: activeImg.tag ?? "",
        digest: activeImg.digest ?? "",
        pullPolicy: "IfNotPresent"
    };

    return { activeSlot: active, inactive };
}

/** Deploy new build to the inactive slot (no traffic switch yet). */
export function applyBlueGreenInactiveImage(
    doc: Record<string, unknown>,
    projectName: string,
    imageTag: string
): { activeSlot: BlueGreenSlot; inactive: BlueGreenSlot } {
    const { activeSlot, inactive } = ensureBlueGreenValuesStructure(doc, projectName, imageTag);
    const { repository, tag, digest } = splitImageRef(imageTag);
    const block = slotImageBlock(doc, inactive);
    const img = block.image as Record<string, unknown>;
    img.repository = repository || buildDeployImageRepository(projectName);
    img.tag = tag;
    img.digest = digest;
    return { activeSlot, inactive };
}

/** Switch Service traffic to the slot that was just updated. */
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
    const prefix = env.ARGOCD_APP_PREFIX.trim() || "paas";
    const release = `${prefix}-${projectName.toLowerCase().replace(/[^a-z0-9-]/g, "-")}`;
    const chart = projectName.toLowerCase().replace(/[^a-z0-9-]/g, "-");
    return `${release}-${chart}-${slot}`;
}
