import fs from "fs";
import path from "path";
import { env } from "@/server/config/env";
import { IntegrationError } from "@/server/http/errors";
import { formatFetchErrorChain } from "@/server/http/format-fetch-error";
import { allowSimulation } from "@/server/integrations/integration-mode";
import { syncInlinePaasDeployJobToJenkins } from "@/server/jenkins/inline-paas-deploy-job-sync";
const JENKINSFILE_SEGMENTS = ["paas", "jenkins", "Jenkinsfile.paas-deploy"] as const;
/** Baked into paas/docker/frontend.Dockerfile when the UI runs as a container without a monorepo volume. */
const BUNDLED_MONOREPO_ROOT = "/app/paas-bundled";
/** Known markers printed by `paas/jenkins/Jenkinsfile.paas-deploy` (accept several so a newer UI syncs an older mounted repo until `git pull`). */
const ACCEPTED_PAAS_JENKINSFILE_MARKERS = [
    "[paas-jenkinsfile] marker=steps-1-2-3-4-5-202602",
    "[paas-jenkinsfile] marker=steps-1-2-3-4-202602",
    "[paas-jenkinsfile] marker=steps-1-2-3-202602"
] as const;
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
        throw new IntegrationError(
            `PAAS_MONOREPO_ROOT is set to "${override}" but paas/jenkins/Jenkinsfile.paas-deploy was not found under that path. ` +
                "Fix the Docker volume in paas/docker-compose.yml (host repo root must be mounted at that path, e.g. ..:/monorepo:ro), " +
                "or clear PAAS_MONOREPO_ROOT to use only the Jenkinsfile baked into the frontend image (rebuild the image after git pull)."
        );
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
    const bundled = path.resolve(BUNDLED_MONOREPO_ROOT);
    if (jenkinsfileRelativePathExists(bundled)) {
        return bundled;
    }
    return null;
}
export async function syncInlinePaasDeployJenkinsJobBeforeTrigger(jobName: string): Promise<string> {
    const flag = env.JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER.trim();
    const mountHint = env.PAAS_MONOREPO_ROOT.trim();
    const mounted = Boolean(mountHint && jenkinsfileRelativePathExists(path.resolve(mountHint)));
    const root = findMonorepoRoot();
    const shouldSync = flag === "true" || mounted || (flag !== "false" && root !== null);
    if (!shouldSync) {
        return `[jenkins-sync] Skipped (JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=${flag}; mounted Jenkinsfile=${mounted}).`;
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
        throw new IntegrationError("Cannot find Jenkinsfile.paas-deploy (tried PAAS_MONOREPO_ROOT, cwd parents, and /app/paas-bundled from the frontend image). Rebuild the frontend image or set PAAS_MONOREPO_ROOT to the repo root that contains paas/jenkins/.");
    }
    const jenkinsfilePath = path.join(root, ...JENKINSFILE_SEGMENTS);
    if (!fs.existsSync(jenkinsfilePath)) {
        throw new IntegrationError(`Missing Jenkinsfile for sync: ${jenkinsfilePath}`);
    }
    const groovy = fs.readFileSync(jenkinsfilePath, "utf-8").replace(/^\uFEFF/, "").replace(/\r\n/g, "\n");
    if (/stage\s*\(\s*["']Step 1 — Validate parameters and checkout["']/m.test(groovy)) {
        throw new IntegrationError(
            "The Jenkinsfile used for sync is an obsolete one-stage stub (merged validate+checkout). " +
                "It cannot be pushed to Jenkins. Use a current paas/jenkins/Jenkinsfile.paas-deploy from the repo: " +
                "fix PAAS_MONOREPO_ROOT + volume, or rebuild the frontend image (docker compose build --no-cache frontend) so the COPY step picks up the new file."
        );
    }
    if (!ACCEPTED_PAAS_JENKINSFILE_MARKERS.some((m) => groovy.includes(m))) {
        throw new IntegrationError(
            `Jenkinsfile at ${jenkinsfilePath} does not contain a recognized PaaS pipeline marker (expected one of: ${ACCEPTED_PAAS_JENKINSFILE_MARKERS.join(", ")}). ` +
                "Git pull the devsecops monorepo on the host that mounts this path (e.g. /monorepo) so paas/jenkins/Jenkinsfile.paas-deploy is current, then retry."
        );
    }
    try {
        const out = await syncInlinePaasDeployJobToJenkins({
            jobName: trimmedJob,
            groovyScript: groovy,
            jenkinsfileLabel: path.basename(jenkinsfilePath)
        });
        return `[jenkins-sync] OK — source: ${root} → job "${trimmedJob}"\n${out}`.trim();
    }
    catch (err: unknown) {
        const detail = formatFetchErrorChain(err);
        const netLike = /fetch failed|ECONNREFUSED|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|timed out|network|connect/i.test(detail);
        const hint = netLike
            ? " If you run the UI in Docker, JENKINS_BASE_URL must be reachable from inside the container (try http://host.docker.internal:<jenkins-port> on Docker Desktop or Linux with host-gateway, or the swarm ingress hostname), not only from your laptop."
            : "";
        throw new IntegrationError(`Jenkins job sync failed:\n${detail}${hint}`);
    }
}
