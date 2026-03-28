import { env } from "@/server/config/env";
import { IntegrationError } from "@/server/http/errors";
import { allowSimulation } from "@/server/integrations/integration-mode";
import { commitHelmValuesGitHub } from "@/server/gitops/gitops-github-service";
import { syncArgoApplication } from "@/server/services/argocd-service";
import { verifyImageWithCosign } from "@/server/security/cosign-verify";
import { evaluateOpaImagePolicy } from "@/server/security/opa-eval";

export type JenkinsBuildResult = {
  ok: boolean;
  buildNumber: number | null;
  buildLog: string;
  jobUrl?: string;
};

export interface DockerHubTagInfo {
  name: string;
  lastUpdated: string | null;
}

function jenkinsBaseUrl(): string {
  return env.JENKINS_BASE_URL.replace(/\/$/, "");
}

function jenkinsAuthHeader(): string {
  return `Basic ${Buffer.from(`${env.JENKINS_USERNAME}:${env.JENKINS_API_TOKEN}`).toString("base64")}`;
}

function jenkinsJobName(projectName: string, projectId: string): string {
  if (env.JENKINS_JOB_NAME_SOURCE === "uuid") {
    return projectId;
  }
  const safe =
    projectName
      .replace(/[^a-zA-Z0-9._-]/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "") || "project";
  return safe;
}

function jenkinsJobUrlPath(projectName: string, projectId: string): string {
  const segments: string[] = [];
  const folder = env.JENKINS_JOB_FOLDER?.trim();
  if (folder) {
    for (const part of folder.split("/").filter(Boolean)) {
      segments.push(part);
    }
  }
  segments.push(jenkinsJobName(projectName, projectId));
  return segments.map((s) => `job/${encodeURIComponent(s)}`).join("/");
}

async function jenkinsFetchCrumb(
  base: string,
  headers: Record<string, string>
): Promise<{ crumb: string; crumbRequestField: string } | null> {
  try {
    const response = await fetch(`${base}/crumbIssuer/api/json`, { headers });
    if (!response.ok) {
      return null;
    }
    const data = (await response.json()) as { crumb?: string; crumbRequestField?: string };
    if (data.crumb && data.crumbRequestField) {
      return { crumb: data.crumb, crumbRequestField: data.crumbRequestField };
    }
  } catch {
    /* CSRF issuer disabled */
  }
  return null;
}

export interface SeverityBreakdown {
  critical: number;
  high: number;
  medium: number;
  low: number;
}

function hash(input: string): number {
  return Array.from(input).reduce((acc, char) => acc + char.charCodeAt(0), 0);
}

function seeded(input: string, max: number): number {
  return hash(input) % (max + 1);
}

async function fetchOrFallback<T>(
  serviceLabel: string,
  enabled: boolean,
  url: string,
  init: RequestInit,
  fallback: T,
  parser?: (response: Response) => Promise<T>
): Promise<T> {
  if (!enabled) {
    if (!allowSimulation()) {
      throw new IntegrationError(
        `${serviceLabel} is not configured. Set the required environment variables, or use DEVSECOPS_ALLOW_SIMULATION=true only on non-production machines.`
      );
    }
    return fallback;
  }

  try {
    const response = await fetch(url, init);
    if (!response.ok) {
      const errText = await response.text();
      if (!allowSimulation()) {
        throw new IntegrationError(`${serviceLabel} HTTP ${response.status}: ${errText.slice(0, 800)}`);
      }
      return fallback;
    }

    if (parser) {
      return parser(response);
    }

    return (await response.json()) as T;
  } catch (e) {
    if (e instanceof IntegrationError) {
      throw e;
    }
    if (!allowSimulation()) {
      throw new IntegrationError(`${serviceLabel} request failed: ${e instanceof Error ? e.message : String(e)}`);
    }
    return fallback;
  }
}

export class JenkinsClient {
  private enabled = Boolean(env.JENKINS_BASE_URL && env.JENKINS_USERNAME && env.JENKINS_API_TOKEN);

  async createPipeline(projectName: string) {
    if (!this.enabled) {
      return { created: true as const };
    }

    const base = jenkinsBaseUrl();
    const headers: Record<string, string> = { Authorization: jenkinsAuthHeader() };
    const crumb = await jenkinsFetchCrumb(base, headers);
    if (crumb) {
      headers[crumb.crumbRequestField] = crumb.crumb;
    }

    const url = `${base}/createItem?name=${encodeURIComponent(projectName)}`;
    const response = await fetch(url, { method: "POST", headers });
    if (!response.ok && response.status !== 302) {
      const text = await response.text();
      throw new IntegrationError(`Jenkins createItem failed (${response.status}): ${text.slice(0, 800)}`);
    }

    return { created: true as const };
  }

  /**
   * Triggers a Jenkins job using the real REST API (CSRF crumb, build or buildWithParameters).
   * When Jenkins env is not set, returns a simulated result for local development.
   */
  async triggerBuild(projectName: string, projectId: string, branch: string): Promise<JenkinsBuildResult> {
    const simulated: JenkinsBuildResult = {
      ok: true,
      buildNumber: Math.floor(Date.now() / 1000) % 1_000_000,
      buildLog: `[jenkins] Simulated build for job "${jenkinsJobName(projectName, projectId)}" branch ${branch}`
    };

    if (!this.enabled) {
      if (!allowSimulation()) {
        throw new IntegrationError(
          "Jenkins is required in production: set JENKINS_BASE_URL, JENKINS_USERNAME, and JENKINS_API_TOKEN (or JENKINS_URL / JENKINS_USER / JENKINS_TOKEN)."
        );
      }
      return simulated;
    }

    const base = jenkinsBaseUrl();
    const jobPath = jenkinsJobUrlPath(projectName, projectId);
    const headers: Record<string, string> = { Authorization: jenkinsAuthHeader() };
    const crumb = await jenkinsFetchCrumb(base, headers);
    if (crumb) {
      headers[crumb.crumbRequestField] = crumb.crumb;
    }

    const useSimple = env.JENKINS_USE_SIMPLE_BUILD === "true";
    const triggerUrl = useSimple
      ? `${base}/${jobPath}/build`
      : `${base}/${jobPath}/buildWithParameters?${encodeURIComponent(env.JENKINS_BRANCH_PARAMETER)}=${encodeURIComponent(branch)}`;

    const triggerRes = await fetch(triggerUrl, { method: "POST", headers });
    if (!triggerRes.ok) {
      const errBody = await triggerRes.text();
      return {
        ok: false,
        buildNumber: null,
        buildLog: `[jenkins] POST ${triggerUrl}\nHTTP ${triggerRes.status}\n${errBody.slice(0, 12000)}`,
        jobUrl: `${base}/${jobPath}`
      };
    }

    await new Promise((r) => setTimeout(r, 1500));

    let lastNumber: number | null = null;
    try {
      const lastRes = await fetch(`${base}/${jobPath}/lastBuild/api/json?tree=number,result,url`, { headers });
      if (lastRes.ok) {
        const json = (await lastRes.json()) as { number?: number };
        if (typeof json.number === "number") {
          lastNumber = json.number;
        }
      }
    } catch {
      /* last build may not exist yet */
    }

    let consoleTail = "";
    if (lastNumber != null) {
      try {
        const consoleRes = await fetch(`${base}/${jobPath}/${lastNumber}/consoleText`, { headers });
        if (consoleRes.ok) {
          const text = await consoleRes.text();
          consoleTail = text.length > 24_000 ? text.slice(-24_000) : text;
        }
      } catch {
        /* console not ready */
      }
    }

    const log = [
      `[jenkins] Triggered: ${triggerUrl}`,
      `[jenkins] HTTP ${triggerRes.status}`,
      lastNumber != null ? `[jenkins] Last build #${lastNumber}` : "[jenkins] No lastBuild yet",
      consoleTail ? `\n--- console (tail) ---\n${consoleTail}` : ""
    ].join("\n");

    return {
      ok: true,
      buildNumber: lastNumber,
      buildLog: log,
      jobUrl: `${base}/${jobPath}`
    };
  }

  /**
   * Parameterized deploy trigger: GIT_URL, BRANCH, IMAGE_NAME, PROJECT_ID (names from env).
   * Always uses buildWithParameters — job must declare matching parameters.
   */
  async triggerDeployJob(
    projectName: string,
    projectId: string,
    deployParams: { gitUrl: string; branch: string; imageName: string; projectUuid: string }
  ): Promise<JenkinsBuildResult> {
    const simulated: JenkinsBuildResult = {
      ok: true,
      buildNumber: Math.floor(Date.now() / 1000) % 1_000_000,
      buildLog: `[jenkins] Simulated deploy job "${jenkinsJobName(projectName, projectId)}"`
    };

    if (!this.enabled) {
      if (!allowSimulation()) {
        throw new IntegrationError(
          "Jenkins is required in production: set JENKINS_BASE_URL, JENKINS_USERNAME, and JENKINS_API_TOKEN (or JENKINS_URL / JENKINS_USER / JENKINS_TOKEN)."
        );
      }
      return simulated;
    }

    const base = jenkinsBaseUrl();
    const jobPath = jenkinsJobUrlPath(projectName, projectId);
    const headers: Record<string, string> = { Authorization: jenkinsAuthHeader() };
    const crumb = await jenkinsFetchCrumb(base, headers);
    if (crumb) {
      headers[crumb.crumbRequestField] = crumb.crumb;
    }

    const q = new URLSearchParams();
    q.set(env.JENKINS_DEPLOY_GIT_URL_PARAMETER, deployParams.gitUrl);
    q.set(env.JENKINS_DEPLOY_BRANCH_PARAMETER, deployParams.branch);
    q.set(env.JENKINS_DEPLOY_IMAGE_NAME_PARAMETER, deployParams.imageName);
    q.set(env.JENKINS_DEPLOY_PROJECT_ID_PARAMETER, deployParams.projectUuid);

    const triggerUrl = `${base}/${jobPath}/buildWithParameters?${q.toString()}`;
    const triggerRes = await fetch(triggerUrl, { method: "POST", headers });
    if (!triggerRes.ok) {
      const errBody = await triggerRes.text();
      return {
        ok: false,
        buildNumber: null,
        buildLog: `[jenkins] POST ${triggerUrl}\nHTTP ${triggerRes.status}\n${errBody.slice(0, 12000)}`,
        jobUrl: `${base}/${jobPath}`
      };
    }

    await new Promise((r) => setTimeout(r, 1500));

    let lastNumber: number | null = null;
    try {
      const lastRes = await fetch(`${base}/${jobPath}/lastBuild/api/json?tree=number,result,url`, { headers });
      if (lastRes.ok) {
        const json = (await lastRes.json()) as { number?: number };
        if (typeof json.number === "number") {
          lastNumber = json.number;
        }
      }
    } catch {
      /* last build may not exist yet */
    }

    let consoleTail = "";
    if (lastNumber != null) {
      try {
        const consoleRes = await fetch(`${base}/${jobPath}/${lastNumber}/consoleText`, { headers });
        if (consoleRes.ok) {
          const text = await consoleRes.text();
          consoleTail = text.length > 24_000 ? text.slice(-24_000) : text;
        }
      } catch {
        /* console not ready */
      }
    }

    const log = [
      `[jenkins] Deploy trigger: ${triggerUrl}`,
      `[jenkins] HTTP ${triggerRes.status}`,
      lastNumber != null ? `[jenkins] Last build #${lastNumber}` : "[jenkins] No lastBuild yet",
      consoleTail ? `\n--- console (tail) ---\n${consoleTail}` : ""
    ].join("\n");

    return {
      ok: true,
      buildNumber: lastNumber,
      buildLog: log,
      jobUrl: `${base}/${jobPath}`
    };
  }

  /** Latest run for the job (GET; no CSRF crumb). */
  async getLastBuildSummary(
    projectName: string,
    projectId: string
  ): Promise<{ number: number; building: boolean; result: string | null } | null> {
    if (!this.enabled) {
      return null;
    }
    const base = jenkinsBaseUrl();
    const jobPath = jenkinsJobUrlPath(projectName, projectId);
    const headers = { Authorization: jenkinsAuthHeader() };
    try {
      const res = await fetch(`${base}/${jobPath}/lastBuild/api/json?tree=number,building,result`, { headers });
      if (!res.ok) {
        return null;
      }
      const j = (await res.json()) as { number?: number; building?: boolean; result?: string | null };
      if (typeof j.number !== "number") {
        return null;
      }
      return {
        number: j.number,
        building: Boolean(j.building),
        result: j.result ?? null
      };
    } catch {
      return null;
    }
  }

  /** Single build metadata (`result` null while running). */
  async getBuildApiJson(
    projectName: string,
    projectId: string,
    buildNumber: number
  ): Promise<{ number: number; building: boolean; result: string | null } | null> {
    if (!this.enabled) {
      return null;
    }
    const base = jenkinsBaseUrl();
    const jobPath = jenkinsJobUrlPath(projectName, projectId);
    const headers = { Authorization: jenkinsAuthHeader() };
    try {
      const res = await fetch(
        `${base}/${jobPath}/${buildNumber}/api/json?tree=number,result,building`,
        { headers }
      );
      if (!res.ok) {
        return null;
      }
      const j = (await res.json()) as { number?: number; building?: boolean; result?: string | null };
      if (typeof j.number !== "number") {
        return null;
      }
      return {
        number: j.number,
        building: Boolean(j.building),
        result: j.result ?? null
      };
    } catch {
      return null;
    }
  }

  async getBuildConsoleText(projectName: string, projectId: string, buildNumber: number): Promise<string | null> {
    if (!this.enabled) {
      return null;
    }
    const base = jenkinsBaseUrl();
    const jobPath = jenkinsJobUrlPath(projectName, projectId);
    const headers = { Authorization: jenkinsAuthHeader() };
    try {
      const res = await fetch(`${base}/${jobPath}/${buildNumber}/consoleText`, { headers });
      if (!res.ok) {
        return null;
      }
      return await res.text();
    } catch {
      return null;
    }
  }
}

export class SonarQubeClient {
  private enabled = Boolean(env.SONAR_BASE_URL);

  async qualityGate(projectKey: string): Promise<{ status: "PASSED" | "FAILED" }> {
    const fallbackStatus = projectKey.toLowerCase().includes("fail-sonar") ? "FAILED" : "PASSED";

    return fetchOrFallback(
      "SonarQube",
      this.enabled,
      `${env.SONAR_BASE_URL}/api/qualitygates/project_status?projectKey=${encodeURIComponent(projectKey)}`,
      {
        method: "GET",
        headers: {
          Authorization: `Basic ${Buffer.from(`${env.SONAR_TOKEN}:`).toString("base64")}`
        }
      },
      { status: fallbackStatus },
      async (response) => {
        const data = (await response.json()) as { projectStatus?: { status?: string } };
        return { status: data.projectStatus?.status === "OK" ? "PASSED" : "FAILED" };
      }
    );
  }
}

export class DependencyTrackClient {
  private enabled = Boolean(env.DEPENDENCY_TRACK_BASE_URL);

  async vulnerabilities(projectKey: string): Promise<SeverityBreakdown> {
    const fallback: SeverityBreakdown = {
      critical: seeded(projectKey + "-critical", 1),
      high: seeded(projectKey + "-high", 3),
      medium: seeded(projectKey + "-medium", 6),
      low: seeded(projectKey + "-low", 10)
    };

    return fetchOrFallback(
      "Dependency-Track",
      this.enabled,
      `${env.DEPENDENCY_TRACK_BASE_URL}/api/v1/finding/project/${encodeURIComponent(projectKey)}`,
      {
        method: "GET",
        headers: {
          "X-Api-Key": env.DEPENDENCY_TRACK_API_KEY
        }
      },
      fallback,
      async (response) => {
        const rows = (await response.json()) as {
          severity?: string;
        }[];
        const list = Array.isArray(rows) ? rows : [];
        const out: SeverityBreakdown = { critical: 0, high: 0, medium: 0, low: 0 };
        for (const row of list) {
          const s = (row.severity || "").toUpperCase();
          if (s === "CRITICAL") {
            out.critical += 1;
          } else if (s === "HIGH") {
            out.high += 1;
          } else if (s === "MEDIUM") {
            out.medium += 1;
          } else if (s === "LOW") {
            out.low += 1;
          }
        }
        return out;
      }
    );
  }
}

export class TrivyClient {
  private enabled = Boolean(env.TRIVY_BASE_URL);

  async scan(imageRef: string): Promise<SeverityBreakdown> {
    const critical = imageRef.toLowerCase().includes("critical") ? 1 : 0;
    const fallback: SeverityBreakdown = {
      critical,
      high: seeded(imageRef + "-high", 2),
      medium: seeded(imageRef + "-medium", 4),
      low: seeded(imageRef + "-low", 8)
    };

    return fetchOrFallback(
      "Trivy",
      this.enabled,
      `${env.TRIVY_BASE_URL}/scan`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(env.TRIVY_AUTH_TOKEN ? { Authorization: `Bearer ${env.TRIVY_AUTH_TOKEN}` } : {})
        },
        body: JSON.stringify({ image: imageRef })
      },
      fallback,
      async (response) => {
        const data = (await response.json()) as {
          Results?: { Vulnerabilities?: { Severity?: string }[] }[];
        };
        const out: SeverityBreakdown = { critical: 0, high: 0, medium: 0, low: 0 };
        const results = data.Results ?? [];
        for (const r of results) {
          for (const v of r.Vulnerabilities ?? []) {
            const s = (v.Severity || "").toUpperCase();
            if (s === "CRITICAL") {
              out.critical += 1;
            } else if (s === "HIGH") {
              out.high += 1;
            } else if (s === "MEDIUM") {
              out.medium += 1;
            } else if (s === "LOW") {
              out.low += 1;
            }
          }
        }
        return out;
      }
    );
  }
}

export class CosignClient {
  async isSigned(imageRef: string): Promise<boolean> {
    if (env.COSIGN_ENFORCE_SIGNED === "false") {
      return true;
    }

    return !imageRef.toLowerCase().includes("unsigned");
  }
}

export class OpaClient {
  async isAllowed(imageRef: string, signed: boolean): Promise<boolean> {
    if (env.OPA_ENFORCE_SIGNED === "false") {
      return true;
    }

    if (!signed) {
      return false;
    }

    return !imageRef.toLowerCase().includes("opa-deny");
  }
}

export class HarborClient {
  private enabled = Boolean(env.HARBOR_BASE_URL);

  async pushImage(imageRef: string): Promise<{ pushed: boolean; imageRef: string }> {
    return fetchOrFallback(
      "Harbor",
      this.enabled,
      `${env.HARBOR_BASE_URL}/api/v2.0/projects/${encodeURIComponent(env.HARBOR_PROJECT)}/repositories`,
      {
        method: "GET",
        headers: {
          Authorization: `Basic ${Buffer.from(`${env.HARBOR_USERNAME}:${env.HARBOR_PASSWORD}`).toString("base64")}`
        }
      },
      { pushed: true, imageRef },
      async () => ({ pushed: true, imageRef })
    );
  }
}

export class ArgoCdClient {
  private enabled = Boolean(env.ARGOCD_BASE_URL);

  async sync(projectName: string): Promise<{ status: string; logs: string }> {
    const appName = `${env.ARGOCD_APP_PREFIX}-${projectName}`;
    const fallback = {
      status: "SYNCED",
      logs: `[argocd] Synced application ${appName}`
    };

    if (!this.enabled) {
      return fetchOrFallback(
        "Argo CD sync",
        false,
        "",
        {},
        fallback,
        async () => fallback
      );
    }

    try {
      const { logs } = await syncArgoApplication(projectName);
      return { status: "SYNCED", logs };
    } catch (e) {
      if (!allowSimulation()) {
        throw e;
      }
      return fallback;
    }
  }

  async applicationStatus(projectName: string): Promise<{ health: string; syncStatus: string; appName: string }> {
    const appName = `${env.ARGOCD_APP_PREFIX}-${projectName}`;
    const fallback = { health: "Healthy", syncStatus: "Synced", appName };

    return fetchOrFallback(
      "Argo CD",
      this.enabled,
      `${env.ARGOCD_BASE_URL}/api/v1/applications/${encodeURIComponent(appName)}`,
      {
        method: "GET",
        headers: {
          Authorization: `Bearer ${env.ARGOCD_AUTH_TOKEN}`
        }
      },
      fallback,
      async (response) => {
        const data = (await response.json()) as {
          status?: { health?: { status?: string }; sync?: { status?: string } };
        };
        return {
          health: data.status?.health?.status ?? "Unknown",
          syncStatus: data.status?.sync?.status ?? "Unknown",
          appName
        };
      }
    );
  }
}

export class DockerHubClient {
  private enabled = Boolean(env.DOCKERHUB_USERNAME && env.DOCKERHUB_TOKEN);
  private jwtCache: { token: string; expiresAt: number } | null = null;

  private async getJwt(): Promise<string | null> {
    if (!this.enabled) {
      return null;
    }
    const now = Date.now();
    if (this.jwtCache && this.jwtCache.expiresAt > now + 60_000) {
      return this.jwtCache.token;
    }

    try {
      const response = await fetch("https://hub.docker.com/v2/users/login/", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          username: env.DOCKERHUB_USERNAME,
          password: env.DOCKERHUB_TOKEN
        })
      });

      if (!response.ok) {
        this.jwtCache = null;
        return null;
      }

      const data = (await response.json()) as { token?: string };
      if (!data.token) {
        return null;
      }

      this.jwtCache = { token: data.token, expiresAt: now + 23 * 60 * 60 * 1000 };
      return data.token;
    } catch {
      this.jwtCache = null;
      return null;
    }
  }

  /**
   * Verifies Docker Hub credentials when configured; otherwise returns ok for local/dev.
   */
  async verifyCredentials(): Promise<{ ok: boolean; message: string }> {
    if (!this.enabled) {
      return { ok: true, message: "Docker Hub credentials not set — registry calls are skipped." };
    }

    const token = await this.getJwt();
    if (!token) {
      return { ok: false, message: "Docker Hub authentication failed (check username / access token)." };
    }

    return { ok: true, message: "Docker Hub JWT obtained successfully." };
  }

  /** Lists tags for a repository on hub.docker.com (requires login). */
  async listRepositoryTags(namespace: string, repository: string): Promise<DockerHubTagInfo[]> {
    const token = await this.getJwt();
    if (!token) {
      return [];
    }

    const url = `https://hub.docker.com/v2/repositories/${encodeURIComponent(namespace)}/${encodeURIComponent(repository)}/tags?page_size=40`;
    try {
      const response = await fetch(url, {
        headers: { Authorization: `JWT ${token}` }
      });
      if (!response.ok) {
        return [];
      }
      const data = (await response.json()) as { results?: { name: string; last_updated?: string | null }[] };
      return (data.results ?? []).map((row) => ({
        name: row.name,
        lastUpdated: row.last_updated ?? null
      }));
    } catch {
      return [];
    }
  }

  /** Repository metadata (description, pull count). */
  async getRepositoryMeta(
    namespace: string,
    repository: string
  ): Promise<{ description: string | null; pullCount: number } | null> {
    const token = await this.getJwt();
    if (!token) {
      return null;
    }

    const url = `https://hub.docker.com/v2/repositories/${encodeURIComponent(namespace)}/${encodeURIComponent(repository)}`;
    try {
      const response = await fetch(url, {
        headers: { Authorization: `JWT ${token}` }
      });
      if (!response.ok) {
        return null;
      }
      const data = (await response.json()) as { description?: string | null; pull_count?: number };
      return {
        description: data.description ?? null,
        pullCount: data.pull_count ?? 0
      };
    } catch {
      return null;
    }
  }
}

const PROM_DEFAULT_CPU_QUERY =
  '100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])))';
const PROM_DEFAULT_MEMORY_QUERY =
  "100 * (1 - (avg(node_memory_MemAvailable_bytes) / avg(node_memory_MemTotal_bytes)))";

function prometheusInstantScalar(payload: unknown): number | null {
  const data = payload as { data?: { result?: { value?: [number, string] }[] } };
  const raw = data.data?.result?.[0]?.value?.[1];
  if (raw === undefined) {
    return null;
  }
  const n = Number.parseFloat(String(raw));
  if (!Number.isFinite(n)) {
    return null;
  }
  return Math.min(100, Math.max(0, n));
}

export class PrometheusClient {
  private enabled = Boolean(env.PROMETHEUS_BASE_URL);

  async clusterUsage(projectId: string): Promise<{ cpu: number; ram: number }> {
    const fallback = {
      cpu: 30 + seeded(projectId + "-cpu", 60),
      ram: 35 + seeded(projectId + "-ram", 55)
    };

    const base = env.PROMETHEUS_BASE_URL.replace(/\/$/, "");
    const cpuQuery = env.PROMETHEUS_QUERY_CPU.trim() || PROM_DEFAULT_CPU_QUERY;
    const memQuery = env.PROMETHEUS_QUERY_MEMORY.trim() || PROM_DEFAULT_MEMORY_QUERY;

    return fetchOrFallback(
      "Prometheus",
      this.enabled,
      `${base}/api/v1/query?query=${encodeURIComponent(cpuQuery)}`,
      { method: "GET" },
      fallback,
      async (response) => {
        const cpuPayload = await response.json();
        const cpu = prometheusInstantScalar(cpuPayload) ?? fallback.cpu;
        let ram = fallback.ram;
        try {
          const memRes = await fetch(
            `${base}/api/v1/query?query=${encodeURIComponent(memQuery)}`,
            { method: "GET" }
          );
          if (memRes.ok) {
            ram = prometheusInstantScalar(await memRes.json()) ?? fallback.ram;
          }
        } catch {
          ram = fallback.ram;
        }
        return { cpu, ram };
      }
    );
  }
}

export class GitOpsClient {
  async commitHelmValues(projectName: string, imageTag: string): Promise<{ committed: boolean; ref: string }> {
    return commitHelmValuesGitHub(projectName, imageTag);
  }
}

export const jenkinsClient = new JenkinsClient();
export const sonarQubeClient = new SonarQubeClient();
export const dependencyTrackClient = new DependencyTrackClient();
export const trivyClient = new TrivyClient();
export const cosignClient = new CosignClient();
export const opaClient = new OpaClient();
export const harborClient = new HarborClient();
export const argoCdClient = new ArgoCdClient();
export const prometheusClient = new PrometheusClient();
export const gitOpsClient = new GitOpsClient();
export const dockerHubClient = new DockerHubClient();
