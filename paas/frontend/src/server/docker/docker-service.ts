import { createHash } from "crypto";
import { prisma } from "@/server/db/prisma";
import { env } from "@/server/config/env";
import { dockerHubClient } from "@/server/integrations/devsecops-clients";
import { getProjectById } from "@/server/projects/project-service";
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
export async function buildDockerImage(projectId: string) {
    const project = await getProjectById(projectId);
    const tag = `${project.projectName}:${Date.now()}`;
    const ns = env.DOCKERHUB_NAMESPACE || env.DOCKERHUB_USERNAME || "local";
    const imageRef = `${ns}/${tag}`.replace(/^local\//, "");
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
            registry: "local",
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
    const hub = await dockerHubClient.verifyCredentials();
    const ns = env.DOCKERHUB_NAMESPACE || env.DOCKERHUB_USERNAME || "library";
    const base = project.imageTag || `${project.projectName}:latest`;
    const imageRef = base.includes("/") ? base : `${ns}/${base}`;
    const digest = `sha256:${digestFor(imageRef)}`;
    const hubRepo = dockerHubRepoFromImageRef(imageRef, ns);
    let hubExtra = "";
    if (hubRepo && hub.ok) {
        const [tags, meta] = await Promise.all([
            dockerHubClient.listRepositoryTags(hubRepo.namespace, hubRepo.repository),
            dockerHubClient.getRepositoryMeta(hubRepo.namespace, hubRepo.repository)
        ]);
        const tagNames = tags.map((t) => t.name).slice(0, 15);
        hubExtra = [
            `[dockerhub] Repository ${hubRepo.namespace}/${hubRepo.repository}`,
            meta ? `[dockerhub] Pulls (reported): ${meta.pullCount}` : "",
            tagNames.length ? `[dockerhub] Recent tags: ${tagNames.join(", ")}` : "[dockerhub] No tags returned (private or empty)."
        ]
            .filter(Boolean)
            .join("\n");
    }
    const logs = [
        hub.message,
        `[docker] docker push ${imageRef}`,
        `[docker] digest: ${digest}`,
        hubExtra
    ]
        .filter(Boolean)
        .join("\n");
    await prisma.containerImage.create({
        data: {
            projectId,
            imageRef,
            registry: "docker.io",
            action: "PUSH",
            digest,
            logs
        }
    });
    return { imageRef, digest, logs, registryAuthOk: hub.ok };
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
