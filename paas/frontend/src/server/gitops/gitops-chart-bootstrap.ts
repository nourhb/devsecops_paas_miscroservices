import { env } from "@/server/config/env";
import { buildAppIngressHost, resolveLabNodeIp } from "@/server/deploy/app-public-url";
import { normalizeHarborImageRef } from "@/server/deploy/harbor-registry-host";
import { resolveDeploymentStrategy } from "@/server/gitops/gitops-blue-green";
import { resolveDeployProfileSpec, type DeployProfileSpec } from "@/server/deploy/deploy-profile";
import type { BuildProfile } from "@/server/build/build-planner";
import { IntegrationError } from "@/server/http/errors";
import { integrationFetch } from "@/server/http/integration-fetch";
import { gitopsHelmChartPathForProject } from "@/server/gitops/gitops-paths";
import { helmReleaseName } from "@/server/gitops/gitops-blue-green";
import { sanitizeDeployImageName } from "@/server/deploy/deploy-image";
import fs from "node:fs";
const BUNDLED_SIMPLE_APP_CHART = "/app/paas-bundled/paas/gitops/apps/simple-app";
const CHART_RELATIVE_FILES = [
    "Chart.yaml",
    "templates/_helpers.tpl",
    "templates/deployment.yaml",
    "templates/deployment-bluegreen.yaml",
    "templates/service.yaml",
    "templates/ingress.yaml"
];
const githubHeaders = (token: string) => ({
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28"
});
function parseGithubRepo(url: string): {
    owner: string;
    repo: string;
} {
    const cleaned = url.trim().replace(/\.git$/i, "");
    const ssh = cleaned.match(/git@github\.com:([\w.-]+)\/([\w.-]+)$/i);
    if (ssh) {
        return { owner: ssh[1], repo: ssh[2] };
    }
    const https = cleaned.match(/github\.com\/([\w.-]+)\/([\w.-]+)$/i);
    if (https) {
        return { owner: https[1], repo: https[2] };
    }
    throw new IntegrationError(`GITOPS_REPO_URL must be a github.com repository URL. Got: ${url.slice(0, 80)}`);
}
function contentsUrl(owner: string, repo: string, path: string): string {
    const pathEnc = path.split("/").map(encodeURIComponent).join("/");
    return `https://api.github.com/repos/${owner}/${repo}/contents/${pathEnc}`;
}
async function githubGetText(owner: string, repo: string, path: string, branch: string, token: string): Promise<string> {
    const res = await integrationFetch(`${contentsUrl(owner, repo, path)}?ref=${encodeURIComponent(branch)}`, {
        headers: githubHeaders(token)
    });
    if (!res.ok) {
        const t = await res.text();
        throw new IntegrationError(`GitHub GET ${path} failed (${res.status}): ${t.slice(0, 400)}`);
    }
    const meta = (await res.json()) as {
        content?: string;
        encoding?: string;
    };
    if (!meta.content || meta.encoding !== "base64") {
        throw new IntegrationError(`GitHub file ${path} has unexpected payload.`);
    }
    return Buffer.from(meta.content.replace(/\n/g, ""), "base64").toString("utf8");
}
async function githubFileExists(owner: string, repo: string, path: string, branch: string, token: string): Promise<boolean> {
    const res = await integrationFetch(`${contentsUrl(owner, repo, path)}?ref=${encodeURIComponent(branch)}`, {
        headers: githubHeaders(token)
    });
    if (res.status === 404) {
        return false;
    }
    if (!res.ok) {
        const t = await res.text();
        throw new IntegrationError(`GitHub GET ${path} failed (${res.status}): ${t.slice(0, 400)}`);
    }
    return true;
}
async function githubPutText(owner: string, repo: string, path: string, branch: string, token: string, content: string, message: string): Promise<void> {
    const base = contentsUrl(owner, repo, path);
    for (let attempt = 1; attempt <= 10; attempt++) {
        let sha: string | undefined;
        const getRes = await integrationFetch(`${base}?ref=${encodeURIComponent(branch)}`, { headers: githubHeaders(token) });
        if (getRes.ok) {
            const meta = (await getRes.json()) as {
                sha?: string;
            };
            sha = meta.sha;
        }
        else if (getRes.status !== 404) {
            const t = await getRes.text();
            throw new IntegrationError(`GitHub GET ${path} failed (${getRes.status}): ${t.slice(0, 400)}`);
        }
        const body: Record<string, string> = {
            message,
            content: Buffer.from(content, "utf8").toString("base64"),
            branch
        };
        if (sha) {
            body.sha = sha;
        }
        const putRes = await integrationFetch(base, {
            method: "PUT",
            headers: { ...githubHeaders(token), "Content-Type": "application/json" },
            body: JSON.stringify(body)
        });
        if (putRes.ok) {
            return;
        }
        const t = await putRes.text();
        if (putRes.status === 409 && attempt < 10) {
            await new Promise((resolve) => setTimeout(resolve, Math.min(2000, 150 * 2 ** (attempt - 1))));
            continue;
        }
        throw new IntegrationError(`GitHub PUT ${path} failed (${putRes.status}): ${t.slice(0, 600)}`);
    }
}
export async function ensureGitOpsHelmChartFromReference(projectName: string, buildProfile: BuildProfile = "node"): Promise<{
    bootstrapped: boolean;
    filesWritten: string[];
}> {
    if (!env.GITOPS_REPO_URL || !env.GITOPS_REPO_TOKEN) {
        return { bootstrapped: false, filesWritten: [] };
    }
    const { owner, repo } = parseGithubRepo(env.GITOPS_REPO_URL);
    const branch = env.GITOPS_DEFAULT_BRANCH;
    const token = env.GITOPS_REPO_TOKEN;
    const chartPath = gitopsHelmChartPathForProject(projectName);
    const refBase = (env.GITOPS_BOOTSTRAP_CHART_PATH.trim() || "apps/simple-app").replace(/\\/g, "/").replace(/\/$/, "");
    const referenceName = refBase.split("/").filter(Boolean).pop() ?? "simple-app";
    const profileSpec = resolveDeployProfileSpec(buildProfile);
    const chartSlug = sanitizeDeployImageName(projectName);
    const filesWritten: string[] = [];
    for (const rel of CHART_RELATIVE_FILES) {
        const destPath = `${chartPath}/${rel}`;
        if (await githubFileExists(owner, repo, destPath, branch, token)) {
            continue;
        }
        const srcPath = `${refBase}/${rel}`;
        let text = readBundledBootstrapChartFile(rel);
        if (!text) {
            text = await githubGetText(owner, repo, srcPath, branch, token);
        }
        if (referenceName !== chartSlug) {
            text = text.replaceAll(referenceName, chartSlug);
        }
        if (rel === "templates/deployment.yaml") {
            text = patchDeploymentForProfile(text, profileSpec);
        }
        await githubPutText(owner, repo, destPath, branch, token, text, `chore(gitops): bootstrap ${projectName} chart from ${refBase}`);
        filesWritten.push(destPath);
    }
    return { bootstrapped: filesWritten.length > 0, filesWritten };
}
function readBundledBootstrapChartFile(rel: string): string | null {
    const filePath = `${BUNDLED_SIMPLE_APP_CHART}/${rel.replace(/\\/g, "/")}`;
    try {
        return fs.readFileSync(filePath, "utf8");
    }
    catch {
        return null;
    }
}
export function patchDeploymentForNodeWorkload(yaml: string): string {
    return patchDeploymentForProfile(yaml, resolveDeployProfileSpec("node"));
}
function probeDefaultsForProfile(profile: BuildProfile): Record<string, unknown> {
    switch (profile) {
        case "python":
            return {
                readiness: { initialDelaySeconds: 30, periodSeconds: 10, failureThreshold: 12 },
                liveness: { initialDelaySeconds: 90, periodSeconds: 20, failureThreshold: 6 },
            };
        case "static":
            return {
                type: "tcp",
                readiness: { initialDelaySeconds: 3, periodSeconds: 5, failureThreshold: 6 },
                liveness: { initialDelaySeconds: 10, periodSeconds: 15, failureThreshold: 6 },
            };
        default:
            return {
                readiness: { initialDelaySeconds: 5, periodSeconds: 10, failureThreshold: 6 },
                liveness: { initialDelaySeconds: 15, periodSeconds: 20, failureThreshold: 6 },
            };
    }
}
export function patchDeploymentForProfile(yaml: string, profileSpec: DeployProfileSpec): string {
    const port = profileSpec.containerPort;
    let out = yaml.replace(/readOnlyRootFilesystem:\s*true/g, "readOnlyRootFilesystem: false");
    if (!out.includes("containerPort:") && out.includes("containers:")) {
        out = out.replace(/(\s+- name: [^\n]+\n\s+image:)/, `          ports:\n            - name: http\n              containerPort: ${port}\n              protocol: TCP\n$1`);
    }
    out = out.replace(/containerPort:\s*\{\{\s*\.Values\.service\.targetPort[^}]+\}\}/g, `containerPort: {{ .Values.service.targetPort | default ${port} }}`);
    out = out.replace(/value:\s*\{\{\s*\.Values\.service\.targetPort[^}]+\}\}/g, `value: {{ .Values.service.targetPort | default ${port} | quote }}`);
    return out;
}
export function applyDeployValuesDefaults(doc: Record<string, unknown>, projectName: string, buildProfile: BuildProfile = "node", forceRolling = false): void {
    const chartSlug = sanitizeDeployImageName(projectName);
    doc.nameOverride = chartSlug;
    doc.fullnameOverride = helmReleaseName(projectName);
    const profileSpec = resolveDeployProfileSpec(buildProfile);
    if (!doc.imagePullSecrets) {
        doc.imagePullSecrets = [{ name: "harbor-regcred" }];
    }
    const service = doc.service && typeof doc.service === "object" && doc.service !== null
        ? (doc.service as Record<string, unknown>)
        : {};
    doc.service = service;
    service.targetPort = profileSpec.containerPort;
    if (!doc.probes || typeof doc.probes !== "object" || doc.probes === null) {
        doc.probes = probeDefaultsForProfile(buildProfile);
    }
    if (!doc.resources || typeof doc.resources !== "object" || doc.resources === null) {
        doc.resources = {
            limits: { cpu: "300m", memory: "384Mi" },
            requests: { cpu: "50m", memory: "128Mi" }
        };
    }
    if (!Array.isArray(doc.env)) {
        doc.env = [];
    }
    const platformRolling = forceRolling || resolveDeploymentStrategy(null) === "Rolling";
    if (platformRolling) {
        doc.deploymentStrategy = "Rolling";
        delete doc.activeSlot;
        delete doc.blue;
        delete doc.green;
    }
    else if (!doc.deploymentStrategy) {
        doc.deploymentStrategy = "BlueGreen";
        doc.activeSlot = doc.activeSlot === "green" ? "green" : "blue";
    }
    const pinNode = env.APPS_LAB_NODE_SELECTOR.trim();
    if (pinNode) {
        doc.nodeSelector = { "kubernetes.io/hostname": pinNode };
    }
    else {
        delete doc.nodeSelector;
    }
    const labIp = resolveLabNodeIp();
    if (!labIp) {
        return;
    }
    const ingress = doc.ingress && typeof doc.ingress === "object" && doc.ingress !== null
        ? (doc.ingress as Record<string, unknown>)
        : {};
    doc.ingress = ingress;
    if (ingress.enabled === undefined || ingress.enabled === false) {
        ingress.enabled = true;
    }
    const desiredIngressClass = env.APPS_INGRESS_CLASS.trim() || "traefik";
    if (!ingress.className || String(ingress.className) !== desiredIngressClass) {
        ingress.className = desiredIngressClass;
    }
    const hosts = ingress.hosts;
    if (!Array.isArray(hosts) || hosts.length === 0) {
        ingress.hosts = [{ host: buildAppIngressHost(projectName) }];
    }
    else {
        const expectedHost = buildAppIngressHost(projectName);
        const hostEntries = hosts as Array<Record<string, unknown>>;
        const hasExpected = hostEntries.some((entry) => String(entry.host || "").toLowerCase() === expectedHost.toLowerCase());
        if (!hasExpected) {
            hostEntries.unshift({ host: expectedHost });
            ingress.hosts = hostEntries;
        }
    }
    if (!Array.isArray(ingress.tls)) {
        ingress.tls = [];
    }
    const image = doc.image && typeof doc.image === "object" && doc.image !== null
        ? (doc.image as Record<string, unknown>)
        : null;
    if (image && typeof image.repository === "string" && image.repository.trim()) {
        image.repository = normalizeHarborImageRef(image.repository);
    }
    for (const slot of ["blue", "green"] as const) {
        const block = doc[slot];
        if (!block || typeof block !== "object" || block === null) {
            continue;
        }
        const slotImg = (block as Record<string, unknown>).image;
        if (slotImg && typeof slotImg === "object" && slotImg !== null) {
            const repo = (slotImg as Record<string, unknown>).repository;
            if (typeof repo === "string" && repo.trim()) {
                (slotImg as Record<string, unknown>).repository = normalizeHarborImageRef(repo);
            }
        }
    }
}
