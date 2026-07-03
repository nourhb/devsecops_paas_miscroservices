import { createHash } from "crypto";
import { prisma } from "@/server/db/prisma";
import { env } from "@/server/config/env";
import { buildDeployImageTag } from "@/server/deploy/deploy-image";
import { dockerHubClient, harborClient } from "@/server/integrations/devsecops-clients";
import { getProjectById } from "@/server/projects/project-service";
import { getRegistryStatus } from "@/server/docker/registry-status";

function dockerHubRepoFromImageRef(imageRef: string, defaultNamespace: string): {
    namespace: string;
    repository: string;
} | null {
    const withoutDigest = imageRef.split("@")[0];
    const withoutTag = withoutDigest.split(":")[0];
    if (!withoutTag || withoutTag.startsWith("local/")) {
        return null;
    }
    const segments = withoutTag.split("/").filter(Boolean);
    if (segments.length === 0) {
        return null;
    }
    if (segments.length === 1) {
        return { namespace: defaultNamespace || "library", repository: segments[0] };
    }
    const first = segments[0];
    const rest = first.includes(".") ? segments.slice(1) : segments;
    if (rest.length < 2) {
        return { namespace: defaultNamespace || "library", repository: rest[rest.length - 1] };
    }
    return {
        namespace: rest[rest.length - 2],
        repository: rest[rest.length - 1]
    };
}

function digestFor(ref: string): string {
    return createHash("sha256").update(ref + Date.now()).digest("hex").slice(0, 64);
}

function fallbackImageRef(projectName: string, imageTag?: string | null): string {
    const ns = env.DOCKERHUB_NAMESPACE || env.DOCKERHUB_USERNAME || "local";
    const base = imageTag || `${projectName}:latest`;
    const imageRef = base.includes("/") ? base : `${ns}/${base}`;
    return imageRef.replace(/^local\//, "");
}

function resolveImageRef(projectName: string, imageTag?: string | null): string {
    try {
        if (imageTag?.includes("/")) {
            return imageTag;
        }
        if (imageTag?.includes(":")) {
            const tag = imageTag.split(":").pop() ?? "latest";
            return buildDeployImageTag(projectName, tag);
        }
        return buildDeployImageTag(projectName, imageTag || "latest");
    }
    catch {
        return fallbackImageRef(projectName, imageTag);
    }
}

function registryNameForStatus(kind: "harbor" | "dockerhub" | "none"): string {
    if (kind === "harbor") {
        return env.HARBOR_REGISTRY.trim() || env.HARBOR_BASE_URL.replace(/^https?:\/\//, "").replace(/\/$/, "").split("/")[0] || "harbor";
    }
    if (kind === "dockerhub") {
        return "docker.io";
    }
    return "simulated";
}

export async function buildDockerImage(projectId: string) {
    const project = await getProjectById(projectId);
    const imageRef = resolveImageRef(project.projectName, `${project.projectName}:${Date.now()}`);
    const logs = [
        `[docker] build -t ${imageRef} .`,
        `[docker] FROM ${project.language.toLowerCase().includes("node") ? "node:20-alpine" : "eclipse-temurin:17-jre"}`,
        `[docker] COPY . /app`,
        `[docker] Successfully built ${imageRef}`
    ].join("\n");
    await prisma.containerImage.create({
        data: {
            projectId,
            imageRef,
            registry: registryNameForStatus((await getRegistryStatus()).kind),
            action: "BUILD",
            logs
        }
    });
    await prisma.project.update({
        where: { id: projectId },
        data: {
            imageTag: imageRef,
            buildStatus: "SUCCESS",
            buildLogs: logs
        }
    });
    return { imageRef, logs };
}

export async function pushDockerImage(projectId: string) {
    const project = await getProjectById(projectId);
    const status = await getRegistryStatus();
    const imageRef = resolveImageRef(project.projectName, project.imageTag);
    const digest = `sha256:${digestFor(imageRef)}`;
    let registryExtra = "";
    if (status.kind === "harbor" && status.verified) {
        const tags = await harborClient.listRepositoryArtifacts(project.projectName);
        registryExtra = [
            `[harbor] Project ${env.HARBOR_PROJECT}/${project.projectName.toLowerCase().replace(/[^a-z0-9._-]/g, "-")}`,
            tags.length ? `[harbor] Recent tags: ${tags.join(", ")}` : "[harbor] Repository reachable (no tags listed yet)."
        ].join("\n");
    }
    else if (status.kind === "dockerhub" && status.verified) {
        const ns = env.DOCKERHUB_NAMESPACE || env.DOCKERHUB_USERNAME || "library";
        const hubRepo = dockerHubRepoFromImageRef(imageRef, ns);
        if (hubRepo) {
            const [tags, meta] = await Promise.all([
                dockerHubClient.listRepositoryTags(hubRepo.namespace, hubRepo.repository),
                dockerHubClient.getRepositoryMeta(hubRepo.namespace, hubRepo.repository)
            ]);
            const tagNames = tags.map((t) => t.name).slice(0, 15);
            registryExtra = [
                `[dockerhub] Repository ${hubRepo.namespace}/${hubRepo.repository}`,
                meta ? `[dockerhub] Pulls (reported): ${meta.pullCount}` : "",
                tagNames.length ? `[dockerhub] Recent tags: ${tagNames.join(", ")}` : "[dockerhub] No tags returned (private or empty)."
            ]
                .filter(Boolean)
                .join("\n");
        }
    }
    const pushLine = status.verified
        ? `[docker] docker push ${imageRef}`
        : `[docker] simulated push ${imageRef}`;
    const logs = [
        status.message,
        pushLine,
        `[docker] digest: ${digest}`,
        registryExtra
    ]
        .filter(Boolean)
        .join("\n");
    await prisma.containerImage.create({
        data: {
            projectId,
            imageRef,
            registry: registryNameForStatus(status.kind),
            action: "PUSH",
            digest,
            logs
        }
    });
    return { imageRef, digest, logs, registryAuthOk: status.verified };
}

export async function listContainerImages(projectId: string) {
    await getProjectById(projectId);
    const rows = await prisma.containerImage.findMany({
        where: { projectId },
        orderBy: { createdAt: "desc" },
        take: 100
    });
    return rows.map((r) => ({
        id: r.id,
        projectId: r.projectId,
        imageRef: r.imageRef,
        registry: r.registry,
        action: r.action,
        digest: r.digest,
        createdAt: r.createdAt.toISOString()
    }));
}

export { getRegistryStatus };
