import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { fail, ok } from "@/server/http/response";
import { listClusterNamespaces } from "@/server/integrations/kubernetes-client";
export const runtime = "nodejs";
export async function GET(request: NextRequest) {
    try {
        await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const result = await listClusterNamespaces();
        const active = result.items.filter((n) => n.phase === "Active").length;
        const terminating = result.items.filter((n) => n.phase === "Terminating").length;
        return ok({
            configured: result.configured,
            error: result.error || "",
            summary: {
                total: result.items.length,
                active,
                terminating
            },
            namespaces: result.items
        });
    }
    catch (error) {
        return fail(error);
    }
}
