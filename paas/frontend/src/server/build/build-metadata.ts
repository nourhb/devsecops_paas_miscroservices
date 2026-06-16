import type { BuildMode, BuildProfile, BuildProvider, ResolvedBuildPlan } from "@/server/build/build-planner";
const META_PREFIX = "[build-meta]";
export interface BuildRunMetadata {
    provider?: BuildProvider;
    profile?: BuildProfile;
    mode?: BuildMode;
    templateName?: string;
    templateVersion?: string;
    runId?: string | null;
    runNumber?: number | null;
    artifactImage?: string | null;
    artifactDigest?: string | null;
}
function normalizeValue(value: string): string {
    return value.replace(/\s+/g, " ").trim();
}
export function buildMetadataLines(plan: ResolvedBuildPlan, metadata: Omit<BuildRunMetadata, "profile" | "mode" | "templateName" | "templateVersion" | "provider">): string[] {
    const pairs: [
        string,
        string | number | null | undefined
    ][] = [
        ["provider", plan.provider],
        ["profile", plan.profile],
        ["mode", plan.mode],
        ["templateName", plan.templateName],
        ["templateVersion", plan.templateVersion],
        ["runId", metadata.runId],
        ["runNumber", metadata.runNumber],
        ["artifactImage", metadata.artifactImage],
        ["artifactDigest", metadata.artifactDigest]
    ];
    return pairs
        .filter(([, value]) => value !== undefined && value !== null && String(value).trim() !== "")
        .map(([key, value]) => `${META_PREFIX} ${key}=${normalizeValue(String(value))}`);
}
export function prependBuildMetadata(logs: string, plan: ResolvedBuildPlan, metadata: Omit<BuildRunMetadata, "profile" | "mode" | "templateName" | "templateVersion" | "provider">): string {
    const lines = buildMetadataLines(plan, metadata);
    return lines.length > 0 ? `${lines.join("\n")}\n${logs}`.trim() : logs.trim();
}
export function parseBuildMetadata(logs: string | null | undefined): BuildRunMetadata {
    const metadata: BuildRunMetadata = {};
    for (const rawLine of String(logs ?? "").split("\n")) {
        const line = rawLine.trim();
        if (!line.startsWith(META_PREFIX)) {
            continue;
        }
        const payload = line.slice(META_PREFIX.length).trim();
        const [key, ...valueParts] = payload.split("=");
        const value = valueParts.join("=").trim();
        if (!key || !value) {
            continue;
        }
        switch (key.trim()) {
            case "provider":
                if (value === "jenkins" || value === "tekton") {
                    metadata.provider = value;
                }
                break;
            case "profile":
                if (["node", "python", "java", "static", "custom"].includes(value)) {
                    metadata.profile = value as BuildProfile;
                }
                break;
            case "mode":
                if (value === "platform-template" || value === "custom-dockerfile") {
                    metadata.mode = value;
                }
                break;
            case "templateName":
                metadata.templateName = value;
                break;
            case "templateVersion":
                metadata.templateVersion = value;
                break;
            case "runId":
                metadata.runId = value;
                break;
            case "runNumber": {
                const parsed = Number(value);
                metadata.runNumber = Number.isFinite(parsed) ? parsed : null;
                break;
            }
            case "artifactImage":
                metadata.artifactImage = value;
                break;
            case "artifactDigest":
                metadata.artifactDigest = value;
                break;
        }
    }
    return metadata;
}
export function formatArtifactReference(image: string | null | undefined, digest: string | null | undefined): string | null {
    if (!image) {
        return null;
    }
    return digest ? `${image}@${digest}` : image;
}
