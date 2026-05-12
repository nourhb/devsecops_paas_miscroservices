import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { assertProjectAccess } from "@/server/projects/project-service";
import { getProjectById } from "@/server/projects/project-service";
import { fail, ok } from "@/server/http/response";
import { resolveBuildPlan } from "@/server/build-planner";
import { ValidationError } from "@/server/http/errors";
import { jenkinsClient } from "@/server/integrations/devsecops-clients";
export const runtime = "nodejs";
export async function GET(request: NextRequest) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const { searchParams } = new URL(request.url);
        const projectId = (searchParams.get("projectId") || "").trim();
        if (!projectId) {
            throw new ValidationError("projectId is required.");
        }
        await assertProjectAccess(projectId, auth.userId, auth.role);
        const project = await getProjectById(projectId);
        const buildPlan = resolveBuildPlan(project);
        if (buildPlan.provider !== "jenkins") {
            return ok({
                configured: false,
                skipped: true,
                reason: `Live Jenkins stages are only available when the project uses the Jenkins backend (this project is ${buildPlan.provider}).`,
                jobUrlPath: "",
                displayJobName: "",
                buildNumber: null,
                building: false,
                result: null,
                runStatus: null,
                stages: [],
                buildUrl: null
            });
        }
        const bnRaw = searchParams.get("buildNumber");
        const buildNumber = bnRaw === null || bnRaw === "" ? null : Number.parseInt(bnRaw, 10);
        const payload = await jenkinsClient.getWorkflowStagesForProject(project.projectName, project.id, Number.isFinite(buildNumber) ? buildNumber : null);
        return ok(payload);
    }
    catch (error) {
        return fail(error);
    }
}
