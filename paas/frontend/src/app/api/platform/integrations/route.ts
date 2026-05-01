import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { fail, ok } from "@/server/http/response";
import { attachIntegrationHealth } from "@/server/platform/platform-integration-health";
import { buildPlatformIntegrations } from "@/server/platform/platform-integrations";
export const runtime = "nodejs";
export async function GET(request: NextRequest) {
    try {
        requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const payload = buildPlatformIntegrations();
        await attachIntegrationHealth(payload);
        return ok(payload);
    }
    catch (error) {
        return fail(error);
    }
}
