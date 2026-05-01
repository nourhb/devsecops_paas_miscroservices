import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { fail, ok } from "@/server/http/response";
import { listPlatformArtifacts } from "@/server/artifacts/artifact-service";
export const runtime = "nodejs";
export async function GET(request: NextRequest) {
    try {
        requireAuth(request, ["ADMIN", "DEVELOPER"]);
        return ok(await listPlatformArtifacts());
    }
    catch (error) {
        return fail(error);
    }
}
