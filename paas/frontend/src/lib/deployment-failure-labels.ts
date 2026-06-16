const LABELS: Record<string, string> = {
    JENKINS: "Build backend",
    GITOPS: "GitOps",
    ARGOCD: "Argo CD",
    IMAGE_REF: "Image configuration",
    TRIGGER: "Deploy trigger",
    TIMEOUT: "Timeout",
    UNKNOWN: "Unknown"
};

export function deploymentFailureStageLabel(reason: string | null | undefined): string {
    if (!reason) {
        return "";
    }
    return LABELS[reason] ?? reason;
}
