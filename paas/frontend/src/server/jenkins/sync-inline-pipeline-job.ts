import fs from "fs";
import path from "path";
import { env } from "@/server/config/env";
import { IntegrationError } from "@/server/http/errors";
import { formatFetchErrorChain } from "@/server/http/format-fetch-error";
import { allowSimulation } from "@/server/integrations/integration-mode";
import { syncJenkinsfileConfigMapFromEmbeddedIfNeeded } from "@/server/jenkins/jenkinsfile-configmap-sync";
import {
    jenkinsfileHasMultiFrameworkMarker,
    jenkinsfileHasNginxConfWritefileFix,
    jenkinsfileIsValidPaasDeploy,
    readResolvedJenkinsfileGroovy,
    resolveJenkinsfilePath
} from "@/server/jenkins/jenkinsfile-source";
import { syncInlinePaasDeployJobToJenkins } from "@/server/jenkins/inline-paas-deploy-job-sync";
const JENKINSFILE_SEGMENTS = ["paas", "jenkins", "Jenkinsfile.paas-deploy"] as const;
const BROKEN_CRANE_MUTATE_CMD_RE = /--entrypoint=\/bin\/sh\s*\\?\s*\n?\s*--cmd=-c[\s\S]*require\("\\\.\/package\.json"\)/m;
const DEFAULT_JENKINSFILE_RAW_URL = "https://raw.githubusercontent.com/nourhb/devsecops_paas_miscroservices/main/paas/jenkins/Jenkinsfile.paas-deploy";
const STALE_CRANE_NEXT_BUILD_RE = /version\.split\(['"]\.['"]\)\.map\(Number\);process\.exit\(\(v\[0\]\|\|0\)>=16/;

function jenkinsfileHasFixedStep6(groovy: string): boolean {
    return groovy.includes("Step 6a")
        && groovy.includes("entrypoint=/app/start-paas.sh");
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
    if (jenkinsfileIsValidPaasDeploy(localGroovy) && jenkinsfileHasNginxConfWritefileFix(localGroovy)) {
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
    if (!jenkinsfileIsValidPaasDeploy(groovy)) {
        throw new IntegrationError(`Jenkinsfile at ${jenkinsfilePath} is not a valid PaaS deploy pipeline.`);
    }
    if (!jenkinsfileHasNginxConfWritefileFix(groovy)) {
        throw new IntegrationError(`Jenkinsfile at ${jenkinsfilePath} is missing writeNginxPaasDefaultConf.`);
    }
    if (STALE_CRANE_NEXT_BUILD_RE.test(groovy) && !jenkinsfileHasFixedStep6(groovy)) {
        throw new IntegrationError(`Jenkinsfile at ${jenkinsfilePath} has obsolete Step 6 logic.`);
    }
    if (BROKEN_CRANE_MUTATE_CMD_RE.test(groovy)) {
        throw new IntegrationError(`Jenkinsfile at ${jenkinsfilePath} has obsolete Step 6 crane mutate logic.`);
    }
}

function jenkinsfileRelativePathExists(root: string): boolean {
    return fs.existsSync(path.join(root, ...JENKINSFILE_SEGMENTS));
}

function findMonorepoRoot(): string | null {
    const resolved = resolveJenkinsfilePath();
    return resolved?.root ?? null;
}

export async function syncInlinePaasDeployJenkinsJobBeforeTrigger(jobName: string): Promise<string> {
    const flag = env.JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER.trim();
    const mountRoot = env.PAAS_MONOREPO_ROOT.trim();
    const mounted = Boolean(mountRoot && jenkinsfileRelativePathExists(path.resolve(mountRoot)));
    const root = findMonorepoRoot();
    const trimmedJob = jobName.trim();
    const sharedDeployJob = env.JENKINS_DEPLOY_JOB_NAME.trim();
    if (sharedDeployJob && trimmedJob === sharedDeployJob) {
        return `[jenkins-sync] Skipped: shared deploy job "${trimmedJob}" uses CPS multi-load wrapper (run: bash paas/scripts/lab.sh force-fix-paas-deploy).`;
    }
    if (trimmedJob === "paas-deploy") {
        return "[jenkins-sync] Skipped: paas-deploy uses CPS multi-load wrapper (run: bash paas/scripts/lab.sh force-fix-paas-deploy).";
    }
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
    if (!trimmedJob || trimmedJob.includes("/")) {
        return "[jenkins-sync] Skipped: folder-qualified job name (use manual sync for nested jobs).";
    }
    const resolvedPath = resolveJenkinsfilePath();
    if (!resolvedPath) {
        throw new IntegrationError("Jenkinsfile.paas-deploy not found (check PAAS_MONOREPO_ROOT or rebuild frontend image).");
    }
    const cmLog = await syncJenkinsfileConfigMapFromEmbeddedIfNeeded();
    const resolvedGroovy = readResolvedJenkinsfileGroovy();
    if (!resolvedGroovy) {
        throw new IntegrationError("Jenkinsfile.paas-deploy not readable (rebuild frontend image).");
    }
    const jenkinsfilePath = resolvedGroovy.absPath;
    const localGroovy = resolvedGroovy.groovy;
    if (/stage\s*\(\s*["']Step 1 — Validate parameters and checkout["']/m.test(localGroovy)) {
        throw new IntegrationError("Jenkinsfile.paas-deploy is an obsolete stub; use the current file from the repo.");
    }
    if (!jenkinsfileHasMultiFrameworkMarker(localGroovy)) {
        throw new IntegrationError("Jenkinsfile is missing multi-framework support.");
    }
    if (!jenkinsfileHasNginxConfWritefileFix(localGroovy)) {
        throw new IntegrationError("Jenkinsfile is missing writeNginxPaasDefaultConf.");
    }
    const { groovy, sourceLabel } = await resolveGroovyForJenkinsSync(jenkinsfilePath, localGroovy);
    assertPaasDeployJenkinsfileSafeForSync(groovy, sourceLabel);
    try {
        const out = await syncInlinePaasDeployJobToJenkins({
            jobName: trimmedJob,
            groovyScript: groovy,
            jenkinsfileLabel: path.basename(jenkinsfilePath)
        });
        return `[jenkins-sync] OK — source: ${sourceLabel} (${resolvedPath.source}) → job "${trimmedJob}"\n${cmLog}\n${out}`.trim();
    }
    catch (err: unknown) {
        const detail = formatFetchErrorChain(err);
        const netLike = /fetch failed|ECONNREFUSED|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|timed out|network|connect/i.test(detail);
        throw new IntegrationError(netLike ? `Jenkins sync failed (network): ${detail}` : `Jenkins sync failed: ${detail}`);
    }
}
