import { prisma } from "@/server/db/prisma";
import { parseBuildMetadata } from "@/server/build/build-metadata";
import { buildDeployImageRepository } from "@/server/deploy/deploy-image";
import { env } from "@/server/config/env";
import type { ArtifactListResponse, ArtifactRecord } from "@/types";
function imageName(imageRef: string): string {
    const withoutDigest = imageRef.split("@")[0] || imageRef;
    const last = withoutDigest.split("/").filter(Boolean).pop() || withoutDigest;
    return last.split(":")[0] || last;
}
function imageVersion(imageRef: string, fallback: string): string {
    const withoutDigest = imageRef.split("@")[0] || imageRef;
    const last = withoutDigest.split("/").filter(Boolean).pop() || withoutDigest;
    const tag = last.includes(":") ? last.split(":").pop() : "";
    return tag || fallback;
}
function jenkinsBuildUrl(buildNumber: number | null | undefined): string | null {
    if (!buildNumber || !env.JENKINS_BASE_URL.trim()) {
        return null;
    }
    const jobName = env.JENKINS_BUILD_JOB_NAME.trim() || env.JENKINS_DEPLOY_JOB_NAME.trim();
    if (!jobName) {
        return null;
    }
    const base = env.JENKINS_BASE_URL.replace(/\/+$/, "");
    const folder = env.JENKINS_JOB_FOLDER.trim()
        .split("/")
        .map((part) => part.trim())
        .filter(Boolean);
    const segments = [...folder, ...jobName.split("/").filter(Boolean)];
    const jobPath = segments.map((segment) => `/job/${encodeURIComponent(segment)}`).join("");
    return `${base}${jobPath}/${buildNumber}/`;
}
function toRecord(args: {
    imageRef: string;
    digest?: string | null;
    registry: string;
    action: string;
    createdAt: Date;
    linkUrl?: string | null;
}): ArtifactRecord {
    return {
        name: imageName(args.imageRef),
        version: imageVersion(args.imageRef, args.action.toLowerCase()),
        size: "Container image",
        createdAt: args.createdAt.toISOString(),
        downloadUrl: args.linkUrl ?? null,
        repository: args.registry,
        path: args.digest ? `${args.imageRef}@${args.digest}` : args.imageRef,
        status: "Stored"
    };
}
export async function listPlatformArtifacts(): Promise<ArtifactListResponse> {
    const [images, deployments] = await Promise.all([
        prisma.containerImage.findMany({
            orderBy: { createdAt: "desc" },
            take: 100
        }),
        prisma.deployment.findMany({
            orderBy: { createdAt: "desc" },
            take: 100,
            select: {
                createdAt: true,
                logs: true,
                jenkinsBuildNumber: true,
                project: {
                    select: {
                        projectName: true
                    }
                }
            }
        })
    ]);
    const records = new Map<string, ArtifactRecord>();
    for (const row of images) {
        const record = toRecord({
            imageRef: row.imageRef,
            digest: row.digest,
            registry: row.registry,
            action: row.action,
            createdAt: row.createdAt
        });
        records.set(record.path, record);
    }
    for (const row of deployments) {
        const metadata = parseBuildMetadata(row.logs);
        let artifactImage = metadata.artifactImage;
        if (!artifactImage && row.jenkinsBuildNumber) {
            try {
                artifactImage = `${buildDeployImageRepository(row.project.projectName)}:${row.jenkinsBuildNumber}`;
            }
            catch {
                artifactImage = null;
            }
        }
        if (!artifactImage) {
            continue;
        }
        const record = toRecord({
            imageRef: artifactImage,
            digest: metadata.artifactDigest,
            registry: artifactImage.split("/")[0] || "registry",
            action: row.jenkinsBuildNumber ? `build-${row.jenkinsBuildNumber}` : "deployment",
            createdAt: row.createdAt,
            linkUrl: jenkinsBuildUrl(row.jenkinsBuildNumber)
        });
        records.set(record.path, record);
    }
    const artifacts = Array.from(records.values()).sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt));
    return {
        artifacts,
        latestArtifact: artifacts[0] ?? null
    };
}
export async function getPlatformArtifactByName(name: string): Promise<ArtifactRecord | null> {
    const payload = await listPlatformArtifacts();
    return payload.artifacts.find((artifact) => artifact.name === name || artifact.path === name) ?? null;
}
