import { IntegrationError, ValidationError } from "@/server/http/errors";
import { integrationFetch } from "@/server/http/integration-fetch";
import type { BuildProfile } from "@/server/build-planner";
import { env } from "@/server/config/env";
import type { RepositoryLanguageDetectionResponse } from "@/types";
type GitHubRepoRef = {
    owner: string;
    repo: string;
};
function parseGitHubRepo(url: string): GitHubRepoRef {
    const cleaned = url.trim().replace(/\.git$/i, "");
    const ssh = cleaned.match(/^git@github\.com:([\w.-]+)\/([\w.-]+)$/i);
    if (ssh) {
        return { owner: ssh[1], repo: ssh[2] };
    }
    const https = cleaned.match(/^https?:\/\/github\.com\/([\w.-]+)\/([\w.-]+)$/i);
    if (https) {
        return { owner: https[1], repo: https[2] };
    }
    throw new ValidationError("Only GitHub repository URLs are supported for automatic language detection.");
}
function githubHeaders() {
    const headers: Record<string, string> = {
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"
    };
    const token = env.GITHUB_API_TOKEN.trim();
    if (token) {
        headers.Authorization = `Bearer ${token}`;
    }
    return headers;
}
function uniqueBranchCandidates(values: Array<string | null | undefined>): string[] {
    const seen = new Set<string>();
    const candidates: string[] = [];
    for (const value of values) {
        const branch = String(value || "").trim();
        if (!branch) {
            continue;
        }
        const key = branch.toLowerCase();
        if (seen.has(key)) {
            continue;
        }
        seen.add(key);
        candidates.push(branch);
    }
    return candidates;
}
function decodeBase64(content: string) {
    return Buffer.from(content.replace(/\n/g, ""), "base64").toString("utf8");
}
function dependencyRecord(value: unknown): Record<string, string> {
    if (!value || typeof value !== "object") {
        return {};
    }
    return Object.entries(value as Record<string, unknown>).reduce<Record<string, string>>((acc, [key, entry]) => {
        if (typeof entry === "string") {
            acc[key] = entry;
        }
        return acc;
    }, {});
}
function detectFromPackageJson(raw: string): {
    language: string;
    buildProfile: BuildProfile;
    detectionReason: string;
} {
    const parsed = JSON.parse(raw) as {
        dependencies?: Record<string, unknown>;
        devDependencies?: Record<string, unknown>;
    };
    const deps = {
        ...dependencyRecord(parsed.dependencies),
        ...dependencyRecord(parsed.devDependencies)
    };
    const names = Object.keys(deps);
    if (names.includes("next")) {
        return {
            language: "Next.js",
            buildProfile: "node",
            detectionReason: "Detected from package.json dependency \"next\"."
        };
    }
    if (names.includes("@nestjs/core")) {
        return {
            language: "NestJS",
            buildProfile: "node",
            detectionReason: "Detected from package.json dependency \"@nestjs/core\"."
        };
    }
    if (names.includes("@angular/core")) {
        return {
            language: "Angular",
            buildProfile: "node",
            detectionReason: "Detected from package.json dependency \"@angular/core\"."
        };
    }
    if (names.includes("vue")) {
        return {
            language: "Vue",
            buildProfile: "node",
            detectionReason: "Detected from package.json dependency \"vue\"."
        };
    }
    if (names.includes("react")) {
        return {
            language: "React",
            buildProfile: "node",
            detectionReason: "Detected from package.json dependency \"react\"."
        };
    }
    return {
        language: "Node.js",
        buildProfile: "node",
        detectionReason: "Detected from package.json in the repository root."
    };
}
function detectFromPyproject(raw: string): {
    language: string;
    buildProfile: BuildProfile;
    detectionReason: string;
} {
    const value = raw.toLowerCase();
    if (value.includes("django")) {
        return { language: "Django", buildProfile: "python", detectionReason: "Detected from pyproject.toml dependency \"django\"." };
    }
    if (value.includes("fastapi")) {
        return { language: "FastAPI", buildProfile: "python", detectionReason: "Detected from pyproject.toml dependency \"fastapi\"." };
    }
    if (value.includes("flask")) {
        return { language: "Flask", buildProfile: "python", detectionReason: "Detected from pyproject.toml dependency \"flask\"." };
    }
    return { language: "Python", buildProfile: "python", detectionReason: "Detected from pyproject.toml in the repository root." };
}
async function fetchRepoMetadata(repoRef: GitHubRepoRef) {
    const response = await integrationFetch(`https://api.github.com/repos/${repoRef.owner}/${repoRef.repo}`, {
        headers: githubHeaders(),
        cache: "no-store"
    });
    if (!response.ok) {
        const hint = response.status === 404
            ? " Confirm the repository URL is correct and public, or configure GITHUB_API_TOKEN for private repositories."
            : "";
        throw new IntegrationError(`GitHub repository lookup failed with HTTP ${response.status}.${hint}`);
    }
    return response.json() as Promise<{
        default_branch?: string;
        language?: string | null;
    }>;
}
type RepoContentEntry = {
    name?: string;
    type?: string;
    path?: string;
};
async function tryFetchRepoContents(repoRef: GitHubRepoRef, branch: string): Promise<{
    ok: true;
    contents: RepoContentEntry[];
} | {
    ok: false;
    status: number;
}> {
    const response = await integrationFetch(`https://api.github.com/repos/${repoRef.owner}/${repoRef.repo}/contents?ref=${encodeURIComponent(branch)}`, {
        headers: githubHeaders(),
        cache: "no-store"
    });
    if (!response.ok) {
        return { ok: false, status: response.status };
    }
    return {
        ok: true,
        contents: await response.json() as RepoContentEntry[]
    };
}
async function resolveRepositoryBranch(repoRef: GitHubRepoRef, metadata: {
    default_branch?: string;
}, requestedBranch?: string | null): Promise<{
    branch: string;
    contents: RepoContentEntry[];
}> {
    const candidates = uniqueBranchCandidates([
        requestedBranch,
        metadata.default_branch,
        "main",
        "master"
    ]);
    let lastStatus = 404;
    for (const branch of candidates) {
        const result = await tryFetchRepoContents(repoRef, branch);
        if (result.ok) {
            return { branch, contents: result.contents };
        }
        lastStatus = result.status;
        if (result.status !== 404) {
            throw new IntegrationError(`GitHub repository contents lookup failed with HTTP ${result.status}.`);
        }
    }
    const hint = lastStatus === 404
        ? " Confirm the repository URL is correct and public, or configure GITHUB_API_TOKEN for private repositories."
        : "";
    throw new IntegrationError(`GitHub repository contents lookup failed with HTTP ${lastStatus}.${hint}`);
}
async function fetchContentFile(repoRef: GitHubRepoRef, path: string, branch: string) {
    const response = await integrationFetch(`https://api.github.com/repos/${repoRef.owner}/${repoRef.repo}/contents/${path}?ref=${encodeURIComponent(branch)}`, {
        headers: githubHeaders(),
        cache: "no-store"
    });
    if (!response.ok) {
        return null;
    }
    const payload = (await response.json()) as {
        content?: string;
        encoding?: string;
    };
    if (!payload.content || payload.encoding !== "base64") {
        return null;
    }
    return decodeBase64(payload.content);
}
export function buildSuggestedDockerfile(profile: BuildProfile): string {
    switch (profile) {
        case "node":
            return `FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
ENV NODE_ENV=production
EXPOSE 3000
CMD ["npm", "run", "start"]`;
        case "python":
            return `FROM python:3.12-slim
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["python", "-m", "http.server", "8000"]`;
        case "java":
            return `FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
COPY target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]`;
        case "static":
            return `FROM nginx:alpine
COPY . /usr/share/nginx/html
EXPOSE 80`;
        default:
            return `FROM alpine:3.20
WORKDIR /app
COPY . .
EXPOSE 8080
CMD ["sh", "-c", "sleep infinity"]`;
    }
}
function detectFromPrimaryLanguage(primaryLanguage: string | null | undefined): {
    language: string;
    buildProfile: BuildProfile;
    detectionReason: string;
} {
    const value = String(primaryLanguage || "").trim().toLowerCase();
    if (value === "typescript" || value === "javascript") {
        return { language: "Node.js", buildProfile: "node", detectionReason: `Detected from GitHub primary language \"${primaryLanguage}\".` };
    }
    if (value === "python") {
        return { language: "Python", buildProfile: "python", detectionReason: `Detected from GitHub primary language \"${primaryLanguage}\".` };
    }
    if (value === "java" || value === "kotlin") {
        return { language: "Java", buildProfile: "java", detectionReason: `Detected from GitHub primary language \"${primaryLanguage}\".` };
    }
    if (value === "html" || value === "css") {
        return { language: "Static Site", buildProfile: "static", detectionReason: `Detected from GitHub primary language \"${primaryLanguage}\".` };
    }
    return { language: "Custom", buildProfile: "custom", detectionReason: "No managed platform template matched the repository structure." };
}
export async function detectRepositoryLanguage(input: {
    gitRepositoryUrl: string;
    branch?: string | null;
}): Promise<RepositoryLanguageDetectionResponse> {
    const repoRef = parseGitHubRepo(input.gitRepositoryUrl);
    const metadata = await fetchRepoMetadata(repoRef);
    const requestedBranch = (input.branch || "").trim();
    const { branch, contents } = await resolveRepositoryBranch(repoRef, metadata, input.branch);
    const branchWasCorrected = Boolean(requestedBranch && requestedBranch.toLowerCase() !== branch.toLowerCase());
    const names = new Set(contents.map((entry) => (entry.name || "").toLowerCase()));
    const hasDockerfile = names.has("dockerfile") || names.has("containerfile");
    function finalize(core: {
        language: string;
        buildProfile: BuildProfile;
        detectionReason: string;
    }): RepositoryLanguageDetectionResponse {
        const detectionReason = branchWasCorrected
            ? `${core.detectionReason} Using repository branch "${branch}" (${requestedBranch} was not found).`
            : core.detectionReason;
        return {
            ...core,
            detectionReason,
            branch,
            hasDockerfile,
            suggestedDockerfile: hasDockerfile ? undefined : buildSuggestedDockerfile(core.buildProfile)
        };
    }
    if (names.has("package.json")) {
        const packageJson = await fetchContentFile(repoRef, "package.json", branch);
        if (packageJson) {
            return finalize(detectFromPackageJson(packageJson));
        }
    }
    if (names.has("pom.xml")) {
        const pom = await fetchContentFile(repoRef, "pom.xml", branch);
        const isSpring = pom ? /spring-boot|org\.springframework\.boot/i.test(pom) : true;
        return finalize({
            language: isSpring ? "Spring Boot" : "Java",
            buildProfile: "java",
            detectionReason: isSpring ? "Detected from pom.xml with Spring Boot dependencies." : "Detected from pom.xml in the repository root."
        });
    }
    if (names.has("build.gradle") || names.has("build.gradle.kts")) {
        const buildGradle = (await fetchContentFile(repoRef, names.has("build.gradle.kts") ? "build.gradle.kts" : "build.gradle", branch)) || "";
        const isSpring = /org\.springframework\.boot|spring-boot/i.test(buildGradle);
        return finalize({
            language: isSpring ? "Spring Boot" : "Java",
            buildProfile: "java",
            detectionReason: isSpring ? "Detected from Gradle build with Spring Boot plugin." : "Detected from Gradle build files in the repository root."
        });
    }
    if (names.has("pyproject.toml")) {
        const pyproject = await fetchContentFile(repoRef, "pyproject.toml", branch);
        if (pyproject) {
            return finalize(detectFromPyproject(pyproject));
        }
    }
    if (names.has("requirements.txt") || names.has("manage.py")) {
        return finalize({
            language: names.has("manage.py") ? "Django" : "Python",
            buildProfile: "python",
            detectionReason: names.has("manage.py")
                ? "Detected from manage.py in the repository root."
                : "Detected from requirements.txt in the repository root."
        });
    }
    if (names.has("index.html")) {
        return finalize({
            language: "Static Site",
            buildProfile: "static",
            detectionReason: "Detected from index.html in the repository root."
        });
    }
    return finalize(detectFromPrimaryLanguage(metadata.language));
}
