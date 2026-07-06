// API route handles docker registry-status requests
import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { getRegistryStatus } from "@/server/docker/docker-service";
import { ok, fail } from "@/server/http/response";

export const runtime = "nodejs";

export async function GET(request: NextRequest) {
    try {
        await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const status = await getRegistryStatus();
        return ok(status);
    }
    catch (error) {
        return fail(error);
    }
}
