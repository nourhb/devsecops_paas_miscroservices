import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { assertProjectAccess } from "@/server/projects/project-service";
import { fail, ok } from "@/server/http/response";
import { runProjectDeployment } from "@/server/services/deployment-service";

export const runtime = "nodejs";

export async function POST(
  request: NextRequest,
  { params }: { params: { projectId: string } }
) {
  try {
    const auth = requireAuth(request, ["ADMIN", "DEVELOPER"]);
    await assertProjectAccess(params.projectId, auth.userId, auth.role);
    const response = await runProjectDeployment(params.projectId, auth.userId);
    return ok(response);
  } catch (error) {
    return fail(error);
  }
}
