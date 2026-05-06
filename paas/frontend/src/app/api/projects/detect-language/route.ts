import { NextRequest } from "next/server";
import { z } from "zod";
import { requireAuth } from "@/server/auth/auth-guard";
import { fail, ok } from "@/server/http/response";
import { enforceRateLimit } from "@/server/http/rate-limit";
import { detectRepositoryLanguage } from "@/server/projects/repository-language";
export const runtime = "nodejs";
const requestSchema = z.object({
    gitRepositoryUrl: z.string().url(),
    branch: z.string().trim().min(1).max(120).optional()
});
export async function POST(request: NextRequest) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        enforceRateLimit(request, {
            keyPrefix: `project-detect-language:${auth.userId}`,
            windowMs: 60000,
            maxRequests: 20,
            message: "Too many repository detection requests. Please retry in a minute."
        });
        const payload = requestSchema.parse(await request.json().catch(() => ({})));
        return ok(await detectRepositoryLanguage(payload));
    }
    catch (error) {
        return fail(error);
    }
}
