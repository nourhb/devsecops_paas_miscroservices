import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { fail, ok } from "@/server/http/response";
import { listClusterDeployments, getClusterNodeCount } from "@/server/integrations/kubernetes-client";
export const runtime = "nodejs";
export async function GET(request: NextRequest) {
    try {
        await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const [deploymentsResult, nodeCount] = await Promise.all([
            listClusterDeployments(),
            getClusterNodeCount()
        ]);
        return ok({
            configured: deploymentsResult.configured,
            error: deploymentsResult.error || "",
            summary: {
                total: deploymentsResult.items.length,
                healthy: deploymentsResult.items.filter((deployment) => deployment.ready === `${deployment.replicas}/${deployment.replicas}`).length,
                nodes: nodeCount ?? 0
            },
            deployments: deploymentsResult.items
        });
    }
    catch (error) {
        return fail(error);
    }
}
