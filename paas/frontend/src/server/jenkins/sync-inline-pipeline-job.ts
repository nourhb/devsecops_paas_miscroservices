import fs from "fs";
import path from "path";
import { env } from "@/server/config/env";
import { IntegrationError } from "@/server/http/errors";
import { formatFetchErrorChain } from "@/server/http/format-fetch-error";
import { allowSimulation } from "@/server/integrations/integration-mode";
import { syncInlinePaasDeployJobToJenkins } from "@/server/jenkins/inline-paas-deploy-job-sync";
const JENKINSFILE_SEGMENTS = ["paas", "jenkins", "Jenkinsfile.paas-deploy"] as const;
const BUNDLED_MONOREPO_ROOT = "/app/paas-bundled";
const PAAS_JENKINSFILE_MARKER_RE = /\[paas-jenkinsfile\] marker=steps-1-2-3(?:-\d+)*-202602/;
const CRANE_NEXT16_MARKER = "crane-next16-202605";
const COSIGN_SANDBOX_MARKER = "cosign-sandbox-sh-20260531";
function jenkinsfileHasCosignSandboxFix(groovy: string): boolean {
    return groovy.includes(COSIGN_SANDBOX_MARKER) ||
        (groovy.contains("def ensureCosignTool()") && groovy.contains("test -x '${labBin}'"));
}
const STALE_CRANE_NEXT_BUILD_RE = /version\.split\(['"]\.['"]\)\.map\(Number\);process\.exit\(\(v\[0\]\|\|0\)>=16/;
const DEFAULT_JENKINSFILE_RAW_URL = "https://raw.githubusercontent.com/nourhb/devsecops_paas_miscroservices/main/paas/jenkins/Jenkinsfile.paas-deploy";
function jenkinsfileHasFixedStep6(groovy: string): boolean {
    return (groovy.includes("crane-next16-202605: npm ci") ||
        groovy.includes("crane-next16-202605-j48300: npm ci") ||
        groovy.includes("crane-next16-202605-j48300-split") ||
        (groovy.includes("Step 6a") && groovy.includes("foreground cmd; JENKINS-48300")));
}
function jenkinsfileHasCraneFix(groovy: string): boolean {
    return PAAS_JENKINSFILE_MARKER_RE.test(groovy) && groovy.includes(CRANE_NEXT16_MARKER);
}
async function fetchJenkinsfileFromRawUrl(url: string): Promise<string> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 90000);
    try {
        const res = await fetch(url, {
            signal: controller.signal,
            headers: { Accept: "text/plain" },
            cache: "no-store",
        });
        if (!res.ok) {
            throw new IntegrationError(`Failed to download Jenkinsfile (${res.status}) from ${url}`);
        }
        return (await res.text()).replace(/^\uFEFF/, "").replace(/\r\n/g, "\n");
    }
    catch (err: unknown) {
        if (err instanceof IntegrationError) {
            throw err;
        }
        throw new IntegrationError(`Failed to download Jenkinsfile from ${url}: ${formatFetchErrorChain(err)}`);
    }
    finally {
        clearTimeout(timer);
    }
}
async function resolveGroovyForJenkinsSync(localPath: string, localGroovy: string): Promise<{
    groovy: string;
    sourceLabel: string;
}> {
    if (jenkinsfileHasCraneFix(localGroovy)) {
        return { groovy: localGroovy, sourceLabel: localPath };
    }
    const rawUrl = env.JENKINSFILE_SYNC_RAW_URL.trim() || DEFAULT_JENKINSFILE_RAW_URL;
    const fetched = await fetchJenkinsfileFromRawUrl(rawUrl);
    assertPaasDeployJenkinsfileSafeForSync(fetched, rawUrl);
    return {
        groovy: fetched,
        sourceLabel: `${rawUrl} (replaced stale file at ${localPath})`,
    };
}
function assertPaasDeployJenkinsfileSafeForSync(groovy: string, jenkinsfilePath: string): void {
    if (!PAAS_JENKINSFILE_MARKER_RE.test(groovy)) {
        throw new IntegrationError(`Jenkinsfile at ${jenkinsfilePath} is missing the PaaS pipeline marker. Update the repo or remount Jenkinsfile.paas-deploy.`);
    }
    if (!groovy.includes(CRANE_NEXT16_MARKER)) {
        throw new IntegrationError(`Jenkinsfile at ${jenkinsfilePath} is outdated (missing ${CRANE_NEXT16_MARKER}). Run fix-jenkins-paas-deploy-pipeline-lab.sh on the lab VM.`);
    }
    if (!jenkinsfileHasCosignSandboxFix(groovy)) {
        throw new IntegrationError(`Jenkinsfile at ${jenkinsfilePath} is outdated (missing ${COSIGN_SANDBOX_MARKER}). Re-sync paas-deploy from the current repo Jenkinsfile.`);
    }
    if (STALE_CRANE_NEXT_BUILD_RE.test(groovy) && !jenkinsfileHasFixedStep6(groovy)) {
        throw new IntegrationError(`Jenkinsfile at ${jenkinsfilePath} still has obsolete Step 6 logic. Git pull and refresh the Jenkins job from the current Jenkinsfile.`);
    }
}
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
        throw new IntegrationError(`PAAS_MONOREPO_ROOT=${override} but Jenkinsfile.paas-deploy not found there.`);
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
    if (flag === "false") {
        return `[jenkins-sync] Skipped (JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false; mounted Jenkinsfile=${mounted}).`;
    }
    const shouldSync = flag === "true" || mounted || root !== null;
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
        throw new IntegrationError("Jenkinsfile.paas-deploy not found (check PAAS_MONOREPO_ROOT or rebuild frontend image).");
    }
    const jenkinsfilePath = path.join(root, ...JENKINSFILE_SEGMENTS);
    if (!fs.existsSync(jenkinsfilePath)) {
        throw new IntegrationError(`Missing Jenkinsfile for sync: ${jenkinsfilePath}`);
    }
    const localGroovy = fs.readFileSync(jenkinsfilePath, "utf-8").replace(/^\uFEFF/, "").replace(/\r\n/g, "\n");
    if (/stage\s*\(\s*["']Step 1 — Validate parameters and checkout["']/m.test(localGroovy)) {
        throw new IntegrationError("Jenkinsfile.paas-deploy is an obsolete stub; use the current file from the repo.");
    }
    const { groovy, sourceLabel } = await resolveGroovyForJenkinsSync(jenkinsfilePath, localGroovy);
    if (!jenkinsfileHasCraneFix(localGroovy)) {
        assertPaasDeployJenkinsfileSafeForSync(groovy, sourceLabel);
    }
    else {
        assertPaasDeployJenkinsfileSafeForSync(groovy, jenkinsfilePath);
    }
    try {
        const out = await syncInlinePaasDeployJobToJenkins({
            jobName: trimmedJob,
            groovyScript: groovy,
            jenkinsfileLabel: path.basename(jenkinsfilePath)
        });
        return `[jenkins-sync] OK — source: ${sourceLabel} → job "${trimmedJob}"\n${out}`.trim();
    }
    catch (err: unknown) {
        const detail = formatFetchErrorChain(err);
        const netLike = /fetch failed|ECONNREFUSED|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|timed out|network|connect/i.test(detail);
        throw new IntegrationError(netLike ? `Jenkins sync failed (network): ${detail}` : `Jenkins sync failed: ${detail}`);
    }
}
