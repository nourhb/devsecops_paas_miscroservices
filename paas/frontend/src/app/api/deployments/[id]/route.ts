import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { fail, ok } from "@/server/http/response";
import { getDeploymentForUser } from "@/server/services/deployment-service";

export const runtime = "nodejs";

export async function GET(
  request: NextRequest,
  { params }: { params: { id: string } }
) {
  try {
    const auth = requireAuth(request, ["ADMIN", "DEVELOPER"]);
    const payload = await getDeploymentForUser(params.id, auth.userId, auth.role);
    return ok({
      status: payload.status,
      logs: payload.logs,
      buildNumber: payload.buildNumber,
      projectId: payload.projectId,
      id: payload.id,
      url: payload.url,
      failureReason: payload.failureReason,
      failureMessage: payload.failureMessage
    });
  } catch (error) {
    return fail(error);
  }
}
