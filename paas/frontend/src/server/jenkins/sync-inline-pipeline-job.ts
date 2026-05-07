import fs from "fs";
import path from "path";
import { env } from "@/server/config/env";
import { IntegrationError } from "@/server/http/errors";
import { formatFetchErrorChain } from "@/server/http/format-fetch-error";
import { allowSimulation } from "@/server/integrations/integration-mode";
import { syncInlinePaasDeployJobToJenkins } from "@/server/jenkins/inline-paas-deploy-job-sync";

const JENKINSFILE_SEGMENTS = ["paas", "jenkins", "Jenkinsfile.paas-deploy"] as const;

function jenkinsfileRelativePathExists(root: string): boolean {
    return fs.existsSync(path.join(root, ...JENKINSFILE_SEGMENTS));
}

function findMonorepoRoot(): string | null {
    const override = env.PAAS_MONOREPO_ROOT.trim();
    if (override) {
        const abs = path.resolve(override);
        if (jenkinsfileRelativePathExists(abs)) {
            return abs;
        }
    }
    let dir = process.cwd();
    for (let i = 0; i < 10; i++) {
        if (jenkinsfileRelativePathExists(dir)) {
            return dir;
        }
        const parent = path.dirname(dir);
        if (parent === dir) {
            break;
        }
        dir = parent;
    }
    return null;
}

/**
 * Pushes `Jenkinsfile.paas-deploy` into Jenkins as an inline Pipeline job (REST, same process as Next.js).
 * Skipped when simulation mode, Jenkins folder layouts, or unsupported multi-segment job names.
 */
export async function syncInlinePaasDeployJenkinsJobBeforeTrigger(jobName: string): Promise<string> {
    const rawFlag = process.env.JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER;
    const flag = rawFlag === undefined || rawFlag === null ? "" : String(rawFlag).trim();
    const mountHint = env.PAAS_MONOREPO_ROOT.trim();
    const mounted = Boolean(mountHint && jenkinsfileRelativePathExists(path.resolve(mountHint)));
    const root = findMonorepoRoot();
    /** Sync when explicitly on, Docker Compose mounted the repo (typical: PAAS_MONOREPO_ROOT=/monorepo), or repo is discoverable and sync was not explicitly turned off. */
    const shouldSync = flag === "true" || mounted || (flag !== "false" && root !== null);
    if (!shouldSync) {
        return `[jenkins-sync] Skipped (JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=${flag || "unset"}; mounted Jenkinsfile=${mounted}).`;
    }
    if (allowSimulation()) {
        return "[jenkins-sync] Skipped: DEVSECOPS_ALLOW_SIMULATION=true.";
    }
    if (!env.JENKINS_BASE_URL.trim() || !env.JENKINS_USERNAME.trim() || !env.JENKINS_API_TOKEN.trim()) {
        return "[jenkins-sync] Skipped: Jenkins not configured.";
    }
    if (env.JENKINS_JOB_FOLDER.trim()) {
        return "[jenkins-sync] Skipped: JENKINS_JOB_FOLDER is set (REST sync targets /job/<name> only). Configure folder jobs manually in Jenkins if needed.";
    }
    const trimmedJob = jobName.trim();
    if (!trimmedJob || trimmedJob.includes("/")) {
        return "[jenkins-sync] Skipped: folder-qualified job name (use manual sync for nested jobs).";
    }

    if (!root) {
        throw new IntegrationError(
            "Cannot find monorepo root (expected paas/jenkins/Jenkinsfile.paas-deploy). Set PAAS_MONOREPO_ROOT or run the app from inside the repository."
        );
    }
    const jenkinsfilePath = path.join(root, ...JENKINSFILE_SEGMENTS);
    if (!fs.existsSync(jenkinsfilePath)) {
        throw new IntegrationError(`Missing Jenkinsfile for sync: ${jenkinsfilePath}`);
    }

    const groovy = fs.readFileSync(jenkinsfilePath, "utf-8").replace(/^\uFEFF/, "").replace(/\r\n/g, "\n");

    try {
        const out = await syncInlinePaasDeployJobToJenkins({
            jobName: trimmedJob,
            groovyScript: groovy,
            jenkinsfileLabel: path.basename(jenkinsfilePath)
        });
        return `[jenkins-sync] OK (${trimmedJob})\n${out}`.trim();
    } catch (err: unknown) {
        const detail = formatFetchErrorChain(err);
        const netLike =
            /fetch failed|ECONNREFUSED|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|timed out|network|connect/i.test(detail);
        const hint = netLike
            ? " If you run the UI in Docker, JENKINS_BASE_URL must be reachable from inside the container (try http://host.docker.internal:<jenkins-port> on Docker Desktop or Linux with host-gateway, or the swarm ingress hostname), not only from your laptop."
            : "";
        throw new IntegrationError(`Jenkins job sync failed:\n${detail}${hint}`);
    }
}
