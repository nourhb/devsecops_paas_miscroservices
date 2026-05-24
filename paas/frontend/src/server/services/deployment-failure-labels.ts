import type { DeploymentFailureReason } from "@prisma/client";
const labels: Record<DeploymentFailureReason, string> = {
    JENKINS: "Build backend",
    GITOPS: "GitOps",
    ARGOCD: "Argo CD",
    IMAGE_REF: "Image configuration",
    TRIGGER: "Deploy trigger",
    TIMEOUT: "Timeout",
    UNKNOWN: "Unknown"
};
export function humanizeFailureReason(reason: DeploymentFailureReason | null): string {
    if (!reason) {
        return "";
    }
    return labels[reason] ?? reason;
}
