import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { fail, ok } from "@/server/http/response";
import { ValidationError } from "@/server/http/errors";
import { assertProjectAccess, getProjectById } from "@/server/projects/project-service";
import { dependencyTrackClient } from "@/server/integrations/devsecops-clients";
export const runtime = "nodejs";
export async function GET(request: NextRequest) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const projectId = String(new URL(request.url).searchParams.get("projectId") || "").trim();
        if (!projectId) {
            throw new ValidationError("projectId is required.");
        }
        await assertProjectAccess(projectId, auth.userId, auth.role);
        const project = await getProjectById(projectId);
        let dependencyTrack = await dependencyTrackClient.projectMetrics(project.id);
        if (!dependencyTrack.projectUuid && project.projectName !== project.id) {
            const byName = await dependencyTrackClient.projectMetrics(project.projectName);
            if (byName.projectUuid) {
                dependencyTrack = byName;
            }
        }
        const metrics = dependencyTrack.metrics;
        const summary = metrics.critical > 0
            ? `Build succeeded, but Dependency-Track reports ${metrics.critical} critical vulnerabilities.`
            : metrics.high > 0
                ? `Build succeeded with ${metrics.high} high-severity Dependency-Track findings.`
                : "Build and Dependency-Track security checks are currently clear of critical issues.";
        return ok({
            projectId,
            projectName: project.projectName,
            projectUuid: dependencyTrack.projectUuid,
            metrics,
            findings: dependencyTrack.findings,
            summary
        });
    }
    catch (error) {
        return fail(error);
    }
}
