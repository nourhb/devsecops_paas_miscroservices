import { buildDeployImageRepository } from "@/server/deploy/deploy-image";

/** PAAS_BUILD_COMPLETE is emitted at the end of the log; the 5k progressive tail often drops it. */
export function pickJenkinsLogForArtifactVerify(progressiveTail: string, fullConsole: string | null | undefined): string {
    if (/PAAS_BUILD_COMPLETE\s+result=/i.test(progressiveTail)) {
        return progressiveTail;
    }
    const full = fullConsole?.trim();
    if (full) {
        return full;
    }
    return progressiveTail;
}

export function resolveVerifiedArtifactImage(log: string, projectId: string, projectName: string, buildNum: number): {
    image: string | null;
    error: string | null;
} {
    const expectedRepo = buildDeployImageRepository(projectName).toLowerCase();
    const completeMatches = [...log.matchAll(/PAAS_BUILD_COMPLETE\s+result=(\S+)\s+image=(\S+)\s+project=(\S+)\s+build=(\S+)/gi)];
    const complete = completeMatches.at(-1);
    if (complete) {
        const [, result, image, proj, build] = complete;
        if (proj.trim() !== projectId.trim()) {
            return {
                image: null,
                error: `Jenkins build #${build} belongs to project ${proj}, not this project (${projectId.slice(0, 8)}…). Another deploy may have reused the shared job run number.`
            };
        }
        if (String(result).toUpperCase() !== "SUCCESS") {
            return {
                image: null,
                error: `Jenkins build #${buildNum} finished with result=${result}.`
            };
        }
        const normalized = image.trim().toLowerCase();
        if (!normalized.startsWith(`${expectedRepo}:`) && !normalized.startsWith(`${expectedRepo}@`)) {
            return {
                image: null,
                error: `Jenkins artifact ${image} does not match expected repository ${expectedRepo}.`
            };
        }
        return { image: image.trim(), error: null };
    }
    const artifactMatches = [...log.matchAll(/PAAS_ARTIFACT_IMAGE=([^\s]+)/g)];
    for (let i = artifactMatches.length - 1; i >= 0; i--) {
        const candidate = artifactMatches[i][1]?.trim() ?? "";
        const normalized = candidate.toLowerCase();
        if (normalized.startsWith(`${expectedRepo}:`) || normalized.startsWith(`${expectedRepo}@`)) {
            return { image: candidate, error: null };
        }
    }
    return {
        image: null,
        error: `No PAAS_BUILD_COMPLETE or PAAS_ARTIFACT_IMAGE for this project in Jenkins build #${buildNum} console. If Jenkins finished SUCCESS, redeploy the PaaS frontend (log tail fix) or open the Jenkins console and search PAAS_BUILD_COMPLETE.`
    };
}
