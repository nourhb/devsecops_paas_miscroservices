import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { fail, ok } from "@/server/http/response";
import { listDeploymentsForProject } from "@/server/services/deployment-service";

export const runtime = "nodejs";

export async function GET(
  request: NextRequest,
  { params }: { params: { id: string } }
) {
  try {
    const auth = requireAuth(request, ["ADMIN", "DEVELOPER"]);
    const items = await listDeploymentsForProject(params.id, auth.userId, auth.role);
    return ok(items);
  } catch (error) {
    return fail(error);
  }
}
