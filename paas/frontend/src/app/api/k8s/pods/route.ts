import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { fail, ok } from "@/server/http/response";
import { listClusterPods } from "@/server/integrations/kubernetes-client";
export const runtime = "nodejs";
export async function GET(request: NextRequest) {
    try {
        await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const result = await listClusterPods();
        const running = result.items.filter((pod) => pod.status === "Running").length;
        const pending = result.items.filter((pod) => pod.status === "Pending").length;
        const failed = result.items.filter((pod) => pod.status === "Failed").length;
        return ok({
            configured: result.configured,
            error: result.error || "",
            summary: {
                total: result.items.length,
                running,
                pending,
                failed
            },
            pods: result.items
        });
    }
    catch (error) {
        return fail(error);
    }
}
