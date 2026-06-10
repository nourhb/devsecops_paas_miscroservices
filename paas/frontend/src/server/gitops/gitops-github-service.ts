import { parse as parseYaml, stringify as stringifyYaml } from "yaml";
import { env } from "@/server/config/env";
import type { BuildProfile } from "@/server/build-planner";
import {
    applyBlueGreenInactiveImage,
    applyRollingImage,
    flipBlueGreenActiveSlot,
    inactiveSlot,
    resolveDeploymentStrategy,
    type BlueGreenSlot
} from "@/server/gitops/gitops-blue-green";
import { applyDeployValuesDefaults, ensureGitOpsHelmChartFromReference } from "@/server/gitops/gitops-chart-bootstrap";
import { mergeBuildEnvIntoHelmValues } from "@/server/projects/project-build-env";
import { withGitOpsRepoLock, sleepMs } from "@/server/gitops/gitops-commit-lock";
import { gitopsHelmChartPathForProject, gitopsValuesPathForProject } from "@/server/gitops/gitops-paths";
import { IntegrationError } from "@/server/http/errors";
import { integrationFetch } from "@/server/http/integration-fetch";
import { allowSimulation } from "@/server/integrations/integration-mode";
export { gitopsHelmChartPathForProject } from "@/server/gitops/gitops-paths";
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
    throw new IntegrationError(`GITOPS_REPO_URL must be a github.com repository URL (HTTPS or git@). Got: ${url.slice(0, 80)}`);
}
function splitImageRef(ref: string): {
    repository: string;
    tag: string;
    digest: string;
} {
    const digestSeparator = ref.indexOf("@sha256:");
    if (digestSeparator > 0) {
        return {
            repository: ref.slice(0, digestSeparator),
            tag: "",
            digest: ref.slice(digestSeparator + 1)
        };
    }
    const lastColon = ref.lastIndexOf(":");
    if (lastColon > 0 && lastColon < ref.length - 1 && !ref.slice(lastColon).includes("/")) {
        return { repository: ref.slice(0, lastColon), tag: ref.slice(lastColon + 1), digest: "" };
    }
    return { repository: ref, tag: "", digest: "" };
}
function setImageTag(doc: Record<string, unknown>, imageTag: string): void {
    const { repository, tag, digest } = splitImageRef(imageTag);
    if (doc.image && typeof doc.image === "object" && doc.image !== null) {
        const img = doc.image as Record<string, unknown>;
        img.repository = repository;
        img.tag = tag;
        img.digest = digest;
        return;
    }
    if (doc.app && typeof doc.app === "object" && doc.app !== null) {
        const app = doc.app as Record<string, unknown>;
        if (app.image && typeof app.image === "object" && app.image !== null) {
            const img = app.image as Record<string, unknown>;
            img.repository = repository;
            img.tag = tag;
            img.digest = digest;
            return;
        }
    }
    doc.imageTag = imageTag;
}
function applyImageToValuesDoc(
    doc: Record<string, unknown>,
    projectName: string,
    imageTag: string,
    blueGreenPhase?: "inactive" | "flip",
    forceRolling?: boolean
): void {
    if (forceRolling) {
        applyRollingImage(doc, projectName, imageTag);
        return;
    }
    if (forceRolling || resolveDeploymentStrategy(null) === "Rolling") {
        applyRollingImage(doc, projectName, imageTag);
        return;
    }
    const strategy = resolveDeploymentStrategy(doc);
    if (strategy !== "BlueGreen") {
        setImageTag(doc, imageTag);
        return;
    }
    if (blueGreenPhase === "flip") {
        flipBlueGreenActiveSlot(doc);
        return;
    }
    applyBlueGreenInactiveImage(doc, projectName, imageTag);
}
function readBlueGreenSlots(doc: Record<string, unknown>): {
    activeSlot: BlueGreenSlot;
    inactiveSlot: BlueGreenSlot;
} {
    const activeSlot: BlueGreenSlot = doc.activeSlot === "green" ? "green" : "blue";
    return { activeSlot, inactiveSlot: inactiveSlot(activeSlot) };
}
const githubHeaders = (token: string) => ({
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28"
});
export async function commitHelmValuesGitHub(projectName: string, imageTag: string, options?: {
    buildProfile?: BuildProfile;
    buildEnv?: Record<string, string> | null;
    /** BlueGreen: deploy image to inactive slot, or flip traffic to that slot. */
    blueGreenPhase?: "inactive" | "flip";
    /** Override BlueGreen — single Rolling deployment (used when blue/green verification fails). */
    forceRolling?: boolean;
}): Promise<{
    committed: boolean;
    ref: string;
    chartBootstrapped: boolean;
    blueGreen?: {
        activeSlot: BlueGreenSlot;
        inactiveSlot: BlueGreenSlot;
    };
}> {
    if (!env.GITOPS_REPO_URL || !env.GITOPS_REPO_TOKEN) {
        if (allowSimulation()) {
            return { committed: true, ref: `simulated:refs/heads/main:${projectName}:${imageTag}`, chartBootstrapped: false };
        }
        throw new IntegrationError("GITOPS_REPO_URL and GITOPS_REPO_TOKEN are required to commit GitOps changes.");
    }
    const { owner, repo } = parseGithubRepo(env.GITOPS_REPO_URL);
    return withGitOpsRepoLock(`${owner}/${repo}`, () => commitHelmValuesGitHubUnlocked(projectName, imageTag, options));
}
async function commitHelmValuesGitHubUnlocked(projectName: string, imageTag: string, options?: {
    buildProfile?: BuildProfile;
    buildEnv?: Record<string, string> | null;
    blueGreenPhase?: "inactive" | "flip";
    forceRolling?: boolean;
}): Promise<{
    committed: boolean;
    ref: string;
    chartBootstrapped: boolean;
    blueGreen?: {
        activeSlot: BlueGreenSlot;
        inactiveSlot: BlueGreenSlot;
    };
}> {
    const buildProfile = options?.buildProfile ?? "node";
    const buildEnv = options?.buildEnv ?? null;
    const forceRolling = options?.forceRolling === true;
    const bgPhase = forceRolling ? undefined : options?.blueGreenPhase;
    if (!env.GITOPS_REPO_URL || !env.GITOPS_REPO_TOKEN) {
        if (allowSimulation()) {
            return { committed: true, ref: `simulated:refs/heads/main:${projectName}:${imageTag}`, chartBootstrapped: false };
        }
        throw new IntegrationError("GITOPS_REPO_URL and GITOPS_REPO_TOKEN are required to commit GitOps changes.");
    }
    const { owner, repo } = parseGithubRepo(env.GITOPS_REPO_URL);
    const bootstrap = await ensureGitOpsHelmChartFromReference(projectName, buildProfile);
    const path = gitopsValuesPathForProject(projectName);
    const branch = env.GITOPS_DEFAULT_BRANCH;
    const token = env.GITOPS_REPO_TOKEN;
    const pathEnc = path.split("/").map(encodeURIComponent).join("/");
    const base = `https://api.github.com/repos/${owner}/${repo}/contents/${pathEnc}`;
    let getRes: Response;
    try {
        getRes = await integrationFetch(`${base}?ref=${encodeURIComponent(branch)}`, {
            headers: githubHeaders(token)
        });
    }
    catch (e) {
        if (allowSimulation()) {
            return {
                committed: true,
                ref: `simulated:gitops:get:${branch}:${projectName}:${imageTag} (GitHub unreachable)`,
                chartBootstrapped: false
            };
        }
        throw new IntegrationError(`GitHub GET ${path} failed: ${e instanceof Error ? e.message : String(e)}`);
    }
    const message = bootstrap.bootstrapped
        ? `chore(gitops): bootstrap ${projectName} Helm chart and bump ${imageTag}`
        : forceRolling
            ? `chore(gitops): ${projectName} rolling deploy ${imageTag} (fallback)`
            : bgPhase === "flip"
            ? `chore(gitops): ${projectName} blue-green traffic switch`
            : bgPhase === "inactive"
                ? `chore(gitops): ${projectName} blue-green deploy ${imageTag} (inactive slot)`
                : env.GITOPS_COMMIT_MESSAGE_TEMPLATE.replace(/\{\{projectName\}\}/g, projectName).replace(/\{\{imageTag\}\}/g, imageTag);

    async function loadExistingValues(): Promise<{
        sha?: string;
        contentYaml: string;
    }> {
        const res = await integrationFetch(`${base}?ref=${encodeURIComponent(branch)}`, {
            headers: githubHeaders(token)
        });
    if (res.status === 404) {
        const parts = splitImageRef(imageTag);
        const doc: Record<string, unknown> = {
            image: {
                repository: parts.repository,
                tag: parts.tag,
                pullPolicy: "IfNotPresent"
            }
        };
        applyDeployValuesDefaults(doc, projectName, buildProfile, forceRolling);
        mergeBuildEnvIntoHelmValues(doc, buildEnv);
        if (forceRolling) {
            applyImageToValuesDoc(doc, projectName, imageTag, undefined, true);
        }
        else if (bgPhase !== "flip") {
            applyImageToValuesDoc(doc, projectName, imageTag, bgPhase ?? (resolveDeploymentStrategy(doc) === "BlueGreen" ? "inactive" : undefined));
        }
        else {
            applyImageToValuesDoc(doc, projectName, imageTag, "flip");
        }
        return { contentYaml: stringifyYaml(doc) };
    }
        if (!res.ok) {
            const t = await res.text();
            throw new IntegrationError(`GitHub GET ${path} failed (${res.status}): ${t.slice(0, 600)}`);
        }
        const meta = (await res.json()) as {
            sha?: string;
            content?: string;
            encoding?: string;
        };
        if (!meta.content || meta.encoding !== "base64") {
            throw new IntegrationError(`GitHub file ${path} has unexpected payload (missing base64 content).`);
        }
        const yamlText = Buffer.from(meta.content.replace(/\n/g, ""), "base64").toString("utf8");
        const doc = parseYaml(yamlText) as Record<string, unknown>;
        if (!doc || typeof doc !== "object") {
            throw new IntegrationError(`Values file ${path} is not a YAML object.`);
        }
        applyImageToValuesDoc(doc, projectName, imageTag, bgPhase, forceRolling);
        applyDeployValuesDefaults(doc, projectName, buildProfile, forceRolling);
        mergeBuildEnvIntoHelmValues(doc, buildEnv);
        return { sha: meta.sha, contentYaml: stringifyYaml(doc) };
    }

    let contentYaml: string;
    let sha: string | undefined;
    try {
        if (getRes.status === 404) {
            const loaded = await loadExistingValues();
            contentYaml = loaded.contentYaml;
            sha = loaded.sha;
        }
        else if (!getRes.ok) {
            const t = await getRes.text();
            if (allowSimulation() && (getRes.status === 401 || getRes.status === 403)) {
                return {
                    committed: true,
                    ref: `simulated:gitops:${branch}:${projectName}:${imageTag} (GitHub ${getRes.status} — check GITOPS_REPO_TOKEN or use a real PAT)`,
                    chartBootstrapped: false
                };
            }
            throw new IntegrationError(`GitHub GET ${path} failed (${getRes.status}): ${t.slice(0, 600)}`);
        }
        else {
            const loaded = await loadExistingValues();
            contentYaml = loaded.contentYaml;
            sha = loaded.sha;
        }
    }
    catch (e) {
        if (allowSimulation()) {
            return {
                committed: true,
                ref: `simulated:gitops:get:${branch}:${projectName}:${imageTag} (GitHub unreachable)`,
                chartBootstrapped: false
            };
        }
        throw e;
    }

    for (let attempt = 1; attempt <= 8; attempt++) {
        const body: Record<string, string> = {
            message,
            content: Buffer.from(contentYaml, "utf8").toString("base64"),
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
            const result = (await putRes.json()) as {
                commit?: {
                    sha?: string;
                };
            };
            const parsed = parseYaml(contentYaml) as Record<string, unknown>;
            const blueGreen = resolveDeploymentStrategy(parsed) === "BlueGreen"
                ? readBlueGreenSlots(parsed)
                : undefined;
            return {
                committed: true,
                ref: result.commit?.sha ?? `${branch}:${path}`,
                chartBootstrapped: bootstrap.bootstrapped,
                blueGreen
            };
        }
        const t = await putRes.text();
        if (putRes.status === 409 && attempt < 8) {
            await sleepMs(150 * attempt);
            const refreshed = await loadExistingValues();
            contentYaml = refreshed.contentYaml;
            sha = refreshed.sha;
            continue;
        }
        if (allowSimulation() && (putRes.status === 401 || putRes.status === 403)) {
            return {
                committed: true,
                ref: `simulated:gitops:put:${projectName}:${imageTag} (GitHub ${putRes.status})`,
                chartBootstrapped: bootstrap.bootstrapped
            };
        }
        throw new IntegrationError(`GitHub PUT ${path} failed (${putRes.status}): ${t.slice(0, 800)}`);
    }
    throw new IntegrationError(`GitHub PUT ${path} failed after retries (409 conflict on ${path}).`);
}
