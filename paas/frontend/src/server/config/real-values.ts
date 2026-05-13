const PLACEHOLDER_PATTERNS = [
    "your-",
    "placeholder",
    "changeme",
    "change-this",
    "example.com",
    "localhost",
    "dependencytrack.local",
    "harbor.local",
    "argocd.local",
    "sonarqube.local",
    "trivy.local",
    "your-github-pat",
    "your-jenkins-api-token",
    "your-sonar-token",
    "your-dtrack-api-key"
] as const;
export function isPlaceholderValue(value: string | undefined | null): boolean {
    const s = String(value ?? "").trim().toLowerCase();
    if (!s) {
        return false;
    }
    return PLACEHOLDER_PATTERNS.some((p) => s.includes(p));
}
export function realValueOrEmpty(value: string | undefined | null): string {
    const s = String(value ?? "").trim();
    if (!s || isPlaceholderValue(s)) {
        return "";
    }
    return s;
}
export function isRealConfigured(...values: Array<string | undefined | null>): boolean {
    return values.every((v) => realValueOrEmpty(v) !== "");
}
