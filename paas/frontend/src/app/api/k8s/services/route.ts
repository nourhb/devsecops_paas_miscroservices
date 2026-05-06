import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { fail, ok } from "@/server/http/response";
import { listClusterServices } from "@/server/integrations/kubernetes-client";
export const runtime = "nodejs";
export async function GET(request: NextRequest) {
    try {
        await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const result = await listClusterServices();
        return ok({
            configured: result.configured,
            error: result.error || "",
            summary: {
                total: result.items.length,
                nodePort: result.items.filter((service) => service.type === "NodePort").length,
                loadBalancer: result.items.filter((service) => service.type === "LoadBalancer").length,
                clusterIP: result.items.filter((service) => service.type === "ClusterIP").length
            },
            services: result.items
        });
    }
    catch (error) {
        return fail(error);
    }
}
