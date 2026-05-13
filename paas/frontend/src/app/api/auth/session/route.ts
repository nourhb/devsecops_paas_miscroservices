import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { getAuthUserById } from "@/server/auth/auth-service";
import { fail, ok } from "@/server/http/response";
export const runtime = "nodejs";
export async function GET(request: NextRequest) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const user = await getAuthUserById(auth.userId);
        return ok({
            authenticated: true,
            user: {
                id: auth.userId,
                email: user?.email ?? auth.email,
                fullName: user?.fullName || auth.email,
                role: auth.role,
                accountKind: user?.keycloakSub ? "keycloak" : "local"
            }
        });
    }
    catch (error) {
        return fail(error);
    }
}
