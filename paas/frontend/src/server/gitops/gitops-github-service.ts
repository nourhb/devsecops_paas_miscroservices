import { parse as parseYaml, stringify as stringifyYaml } from "yaml";
import { env } from "@/server/config/env";
import { IntegrationError } from "@/server/http/errors";
import { allowSimulation } from "@/server/integrations/integration-mode";

function parseGithubRepo(url: string): { owner: string; repo: string } {
  const cleaned = url.trim().replace(/\.git$/i, "");
  const ssh = cleaned.match(/git@github\.com:([\w.-]+)\/([\w.-]+)$/i);
  if (ssh) {
    return { owner: ssh[1], repo: ssh[2] };
  }
  const https = cleaned.match(/github\.com\/([\w.-]+)\/([\w.-]+)$/i);
  if (https) {
    return { owner: https[1], repo: https[2] };
  }
  throw new IntegrationError(
    `GITOPS_REPO_URL must be a github.com repository URL (HTTPS or git@). Got: ${url.slice(0, 80)}`
  );
}

function valuesPathForProject(projectName: string): string {
  return env.GITOPS_VALUES_PATH_PATTERN.replace(/\{\{projectName\}\}/gi, projectName).replace(
    /\{\{project\}\}/gi,
    projectName
  );
}

function splitImageRef(ref: string): { repository: string; tag: string } {
  const lastColon = ref.lastIndexOf(":");
  if (lastColon > 0 && lastColon < ref.length - 1 && !ref.slice(lastColon).includes("/")) {
    return { repository: ref.slice(0, lastColon), tag: ref.slice(lastColon + 1) };
  }
  return { repository: ref, tag: "latest" };
}

function setImageTag(doc: Record<string, unknown>, imageTag: string): void {
  const { repository, tag } = splitImageRef(imageTag);
  if (doc.image && typeof doc.image === "object" && doc.image !== null) {
    const img = doc.image as Record<string, unknown>;
    img.repository = repository;
    img.tag = tag;
    return;
  }
  if (doc.app && typeof doc.app === "object" && doc.app !== null) {
    const app = doc.app as Record<string, unknown>;
    if (app.image && typeof app.image === "object" && app.image !== null) {
      const img = app.image as Record<string, unknown>;
      img.repository = repository;
      img.tag = tag;
      return;
    }
  }
  doc.imageTag = imageTag;
}

const githubHeaders = (token: string) => ({
  Authorization: `Bearer ${token}`,
  Accept: "application/vnd.github+json",
  "X-GitHub-Api-Version": "2022-11-28"
});

/**
 * Commits Helm values image tag to GitHub via Contents API (production).
 */
export async function commitHelmValuesGitHub(
  projectName: string,
  imageTag: string
): Promise<{ committed: boolean; ref: string }> {
  if (!env.GITOPS_REPO_URL || !env.GITOPS_REPO_TOKEN) {
    if (allowSimulation()) {
      return { committed: true, ref: `simulated:refs/heads/main:${projectName}:${imageTag}` };
    }
    throw new IntegrationError("GITOPS_REPO_URL and GITOPS_REPO_TOKEN are required to commit GitOps changes.");
  }

  const { owner, repo } = parseGithubRepo(env.GITOPS_REPO_URL);
  const path = valuesPathForProject(projectName);
  const branch = env.GITOPS_DEFAULT_BRANCH;
  const token = env.GITOPS_REPO_TOKEN;
  const pathEnc = path.split("/").map(encodeURIComponent).join("/");
  const base = `https://api.github.com/repos/${owner}/${repo}/contents/${pathEnc}`;

  const getRes = await fetch(`${base}?ref=${encodeURIComponent(branch)}`, {
    headers: githubHeaders(token)
  });

  let sha: string | undefined;
  let contentYaml: string;

  if (getRes.status === 404) {
    const parts = splitImageRef(imageTag);
    contentYaml = stringifyYaml({ image: { repository: parts.repository, tag: parts.tag } });
  } else if (!getRes.ok) {
    const t = await getRes.text();
    throw new IntegrationError(`GitHub GET ${path} failed (${getRes.status}): ${t.slice(0, 600)}`);
  } else {
    const meta = (await getRes.json()) as { sha?: string; content?: string; encoding?: string };
    sha = meta.sha;
    if (!meta.content || meta.encoding !== "base64") {
      throw new IntegrationError(`GitHub file ${path} has unexpected payload (missing base64 content).`);
    }
    contentYaml = Buffer.from(meta.content.replace(/\n/g, ""), "base64").toString("utf8");
    const doc = parseYaml(contentYaml) as Record<string, unknown>;
    if (!doc || typeof doc !== "object") {
      throw new IntegrationError(`Values file ${path} is not a YAML object.`);
    }
    setImageTag(doc, imageTag);
    contentYaml = stringifyYaml(doc);
  }

  const message = env.GITOPS_COMMIT_MESSAGE_TEMPLATE.replace(/\{\{projectName\}\}/g, projectName).replace(
    /\{\{imageTag\}\}/g,
    imageTag
  );

  const body: Record<string, string> = {
    message,
    content: Buffer.from(contentYaml, "utf8").toString("base64"),
    branch
  };
  if (sha) {
    body.sha = sha;
  }

  const putRes = await fetch(base, {
    method: "PUT",
    headers: { ...githubHeaders(token), "Content-Type": "application/json" },
    body: JSON.stringify(body)
  });

  if (!putRes.ok) {
    const t = await putRes.text();
    throw new IntegrationError(`GitHub PUT ${path} failed (${putRes.status}): ${t.slice(0, 800)}`);
  }

  const result = (await putRes.json()) as { commit?: { sha?: string } };
  return {
    committed: true,
    ref: result.commit?.sha ?? `${branch}:${path}`
  };
}
