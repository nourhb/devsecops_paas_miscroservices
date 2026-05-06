import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { fail, ok } from "@/server/http/response";
import { getPlatformTooling } from "@/server/platform/platform-tooling";
export const runtime = "nodejs";
export async function GET(request: NextRequest) {
    try {
        await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        return ok(await getPlatformTooling());
    }
    catch (error) {
        return fail(error);
    }
}
