import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { fail, ok } from "@/server/http/response";
import { getDashboardOverview } from "@/server/services/dashboard-overview-service";

export const runtime = "nodejs";

export async function GET(request: NextRequest) {
  try {
    const auth = requireAuth(request, ["ADMIN", "DEVELOPER"]);
    const overview = await getDashboardOverview(auth.userId, auth.role);
    return ok(overview);
  } catch (error) {
    return fail(error);
  }
}
