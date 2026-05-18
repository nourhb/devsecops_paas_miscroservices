import type { DeployVerifyRow } from "@/components/pipeline/pipeline-verification-panel";

const DEPLOY_LINE = /PAAS_DEPLOY_VERIFY\s+step=(\S+)\s+status=(OK|WARN|FAIL)\s+detail=([^\n\r]+)/gi;

export function parseDeployVerificationFromLogs(logText: string): DeployVerifyRow[] {
    const rows: DeployVerifyRow[] = [];
    for (const m of (logText ?? "").matchAll(DEPLOY_LINE)) {
        rows.push({
            step: m[1],
            status: m[2].toUpperCase() as DeployVerifyRow["status"],
            detail: (m[3] ?? "").trim()
        });
    }
    return rows;
}
