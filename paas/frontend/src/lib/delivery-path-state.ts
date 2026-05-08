export type DeliveryPathStageKey = "build" | "gates" | "registry" | "gitops" | "argo";
export type DeliveryPathVisualState = "done" | "active" | "pending" | "error";
const ORDER: DeliveryPathStageKey[] = ["build", "gates", "registry", "gitops", "argo"];
function up(s: string | null | undefined): string {
    return (s || "").trim().toUpperCase();
}
function combinedLogs(buildLogs?: string | null, deploymentLogs?: string | null): string {
    return [buildLogs || "", deploymentLogs || ""].join("\n");
}
function inferFailedStageIndex(logs: string, buildStatus: string): number {
    const bs = up(buildStatus);
    if (/\[argocd\]\s*FAILED/i.test(logs)) {
        return 4;
    }
    if (/\[gitops\]\s*FAILED/i.test(logs)) {
        return 3;
    }
    if (bs === "PUSHING") {
        return 3;
    }
    if (/\*\*\* BEGIN :\s*9\.\s*Publication/i.test(logs) && /Build backend finished with result:\s*FAILURE|script returned exit code/i.test(logs)) {
        return 2;
    }
    if (/\*\*\* BEGIN :\s*6\.\s*Création de l['']image Docker/i.test(logs) && /Build backend finished with result:\s*FAILURE|script returned exit code/i.test(logs)) {
        return 2;
    }
    if (/\*\*\* BEGIN :\s*3\.\s*SCA/i.test(logs) || /\*\*\* BEGIN :\s*4\.\s*SAST/i.test(logs)) {
        if (/Build backend finished with result:\s*FAILURE|script returned exit code/i.test(logs)) {
            return 1;
        }
    }
    return 0;
}
function inferActiveStageIndex(logs: string): number {
    if (/\*\*\* BEGIN :\s*13\./i.test(logs) || /\*\*\* BEGIN :\s*12\./i.test(logs)) {
        return 4;
    }
    if (/\[gitops\]\s*committed/i.test(logs) || /--- GitOps \(Helm values\) \+ Argo CD ---/i.test(logs)) {
        return 4;
    }
    if (/\*\*\* BEGIN :\s*9\.\s*Publication/i.test(logs)) {
        return 2;
    }
    if (/\*\*\* BEGIN :\s*6\.\s*Création de l['']image Docker/i.test(logs)) {
        return 2;
    }
    if (/\*\*\* END :\s*4\.\s*SAST/i.test(logs) || /\*\*\* BEGIN :\s*6\.\s*Création/i.test(logs)) {
        return 2;
    }
    if (/\*\*\* BEGIN :\s*4\.\s*SAST/i.test(logs)) {
        return 1;
    }
    if (/\*\*\* BEGIN :\s*3\.\s*SCA/i.test(logs)) {
        return 1;
    }
    if (/\*\*\* END :\s*5\.\s*Construction/i.test(logs) || /\*\*\* BEGIN :\s*3\.\s*SCA/i.test(logs)) {
        return 1;
    }
    if (/\*\*\* BEGIN :\s*5\.\s*Construction/i.test(logs)) {
        return 0;
    }
    return 0;
}
function allDone(): Record<DeliveryPathStageKey, DeliveryPathVisualState> {
    return { build: "done", gates: "done", registry: "done", gitops: "done", argo: "done" };
}
export function computeDeliveryPathStates(input: {
    buildStatus: string;
    lastDeploymentStatus: string;
    buildLogs?: string | null;
    deploymentLogs?: string | null;
    argoHealth?: string | null;
    argoSyncStatus?: string | null;
}): Record<DeliveryPathStageKey, DeliveryPathVisualState> {
    const bs = up(input.buildStatus);
    const ds = up(input.lastDeploymentStatus);
    const logs = combinedLogs(input.buildLogs, input.deploymentLogs);
    const deployFailed = ds === "FAILED";
    const deployDone = ds === "DEPLOYED";
    const jenkinsRunning = bs === "BUILDING" || bs === "QUEUED";
    const deployRunning = ds === "DEPLOYING" || ds === "PROMOTING";
    if (deployDone) {
        return allDone();
    }
    if (ds === "PROMOTING") {
        return { build: "done", gates: "done", registry: "done", gitops: "active", argo: "pending" };
    }
    if (deployFailed) {
        const failIx = inferFailedStageIndex(logs, input.buildStatus);
        const out: Partial<Record<DeliveryPathStageKey, DeliveryPathVisualState>> = {};
        for (let i = 0; i < ORDER.length; i++) {
            const key = ORDER[i];
            if (i < failIx) {
                out[key] = "done";
            }
            else if (i === failIx) {
                out[key] = "error";
            }
            else {
                out[key] = "pending";
            }
        }
        return out as Record<DeliveryPathStageKey, DeliveryPathVisualState>;
    }
    const buildTerminalFail = bs === "FAILED" || bs === "FAILURE" || bs === "ABORTED" || bs === "UNSTABLE";
    if (buildTerminalFail) {
        return {
            build: "error",
            gates: "pending",
            registry: "pending",
            gitops: "pending",
            argo: "pending"
        };
    }
    const buildPastCompile = bs === "SUCCESS" || bs === "PUSHING" || bs === "READY";
    if (buildPastCompile && !jenkinsRunning && !deployRunning) {
        if (bs === "READY") {
            return allDone();
        }
        if (bs === "PUSHING") {
            return { build: "done", gates: "done", registry: "done", gitops: "active", argo: "pending" };
        }
        return { build: "done", gates: "done", registry: "pending", gitops: "pending", argo: "pending" };
    }
    if (jenkinsRunning || deployRunning) {
        const activeIx = inferActiveStageIndex(logs);
        const out: Partial<Record<DeliveryPathStageKey, DeliveryPathVisualState>> = {};
        for (let i = 0; i < ORDER.length; i++) {
            const key = ORDER[i];
            if (i < activeIx) {
                out[key] = "done";
            }
            else if (i === activeIx) {
                out[key] = "active";
            }
            else {
                out[key] = "pending";
            }
        }
        const sync = up(input.argoSyncStatus);
        const health = up(input.argoHealth);
        if (deployRunning && (sync === "SYNCED" || health === "HEALTHY" || health === "PROGRESSING")) {
            out.gitops = "done";
            out.argo = health === "HEALTHY" && sync === "SYNCED" ? "done" : "active";
        }
        return out as Record<DeliveryPathStageKey, DeliveryPathVisualState>;
    }
    return {
        build: "pending",
        gates: "pending",
        registry: "pending",
        gitops: "pending",
        argo: "pending"
    };
}
