import { env } from "@/server/config/env";
import { buildAppIngressHost } from "@/server/deploy/app-public-url";
import { resolveDeployProfileSpec, type DeployProfileSpec } from "@/server/deploy/deploy-profile";
import type { BuildProfile } from "@/server/build-planner";
import { IntegrationError } from "@/server/http/errors";
import { integrationFetch } from "@/server/http/integration-fetch";
import { gitopsHelmChartPathForProject } from "@/server/gitops/gitops-paths";
const CHART_RELATIVE_FILES = [
    "Chart.yaml",
    "templates/_helpers.tpl",
    "templates/deployment.yaml",
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
    if (!putRes.ok) {
        const t = await putRes.text();
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
    const chartYamlPath = `${chartPath}/Chart.yaml`;
    if (await githubFileExists(owner, repo, chartYamlPath, branch, token)) {
        return { bootstrapped: false, filesWritten: [] };
    }
    const refBase = (env.GITOPS_BOOTSTRAP_CHART_PATH.trim() || "apps/simple-app").replace(/\\/g, "/").replace(/\/$/, "");
    const referenceName = refBase.split("/").filter(Boolean).pop() ?? "simple-app";
    const profileSpec = resolveDeployProfileSpec(buildProfile);
    const filesWritten: string[] = [];
    for (const rel of CHART_RELATIVE_FILES) {
        const srcPath = `${refBase}/${rel}`;
        const destPath = `${chartPath}/${rel}`;
        let text = await githubGetText(owner, repo, srcPath, branch, token);
        if (referenceName !== projectName) {
            text = text.replaceAll(referenceName, projectName);
        }
        if (rel === "templates/deployment.yaml") {
            text = patchDeploymentForProfile(text, profileSpec);
        }
        await githubPutText(owner, repo, destPath, branch, token, text, `chore(gitops): bootstrap ${projectName} chart from ${refBase}`);
        filesWritten.push(destPath);
    }
    return { bootstrapped: true, filesWritten };
}
export function patchDeploymentForNodeWorkload(yaml: string): string {
    return patchDeploymentForProfile(yaml, resolveDeployProfileSpec("node"));
}
export function patchDeploymentForProfile(yaml: string, profileSpec: DeployProfileSpec): string {
    const port = profileSpec.containerPort;
    let out = yaml
        .replace(/readOnlyRootFilesystem:\s*true/g, "readOnlyRootFilesystem: false")
        .replace(/runAsNonRoot:\s*true/g, "runAsNonRoot: false");
    if (!out.includes("containerPort:") && out.includes("containers:")) {
        out = out.replace(/(\s+- name: [^\n]+\n\s+image:)/, `          ports:\n            - name: http\n              containerPort: ${port}\n              protocol: TCP\n$1`);
    }
    out = out.replace(/containerPort:\s*\{\{\s*\.Values\.service\.targetPort[^}]+\}\}/g, `containerPort: {{ .Values.service.targetPort | default ${port} }}`);
    out = out.replace(/value:\s*\{\{\s*\.Values\.service\.targetPort[^}]+\}\}/g, `value: {{ .Values.service.targetPort | default ${port} | quote }}`);
    return out;
}
export function applyDeployValuesDefaults(doc: Record<string, unknown>, projectName: string, buildProfile: BuildProfile = "node"): void {
    const profileSpec = resolveDeployProfileSpec(buildProfile);
    if (!doc.imagePullSecrets) {
        doc.imagePullSecrets = [{ name: "harbor-regcred" }];
    }
    const service = doc.service && typeof doc.service === "object" && doc.service !== null
        ? (doc.service as Record<string, unknown>)
        : {};
    doc.service = service;
    service.targetPort = profileSpec.containerPort;
    const labIp = env.APPS_PUBLIC_LAB_NODE_IP.trim();
    if (labIp && !doc.nodeSelector) {
        doc.nodeSelector = { "kubernetes.io/hostname": "master" };
    }
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
    if (!ingress.className) {
        ingress.className = env.APPS_INGRESS_CLASS.trim() || "traefik";
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
}
