import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { assertProjectAccess } from "@/server/projects/project-service";
import { getArgoStatusForProject } from "@/server/argocd/argocd-service";
import { fail, ok } from "@/server/http/response";

export const runtime = "nodejs";

export async function GET(
  request: NextRequest,
  { params }: { params: { projectId: string } }
) {
  try {
    const auth = requireAuth(request, ["ADMIN", "DEVELOPER"]);
    await assertProjectAccess(params.projectId, auth.userId, auth.role);
    const status = await getArgoStatusForProject(params.projectId);
    return ok(status);
  } catch (error) {
    return fail(error);
  }
}
