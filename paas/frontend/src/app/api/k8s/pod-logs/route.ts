import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { ValidationError } from "@/server/http/errors";
import { fail, ok } from "@/server/http/response";
import { readPodLog } from "@/server/integrations/kubernetes-client";
export const runtime = "nodejs";
export async function GET(request: NextRequest) {
    try {
        await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const { searchParams } = new URL(request.url);
        const namespace = (searchParams.get("namespace") || "").trim();
        const podName = (searchParams.get("podName") || "").trim();
        const container = (searchParams.get("container") || "").trim();
        if (!namespace) {
            throw new ValidationError("namespace is required.");
        }
        if (!podName) {
            throw new ValidationError("podName is required.");
        }
        const logs = await readPodLog(namespace, podName, container || undefined);
        return ok({
            namespace,
            podName,
            container,
            logs: logs || "No logs returned for this pod."
        });
    }
    catch (error) {
        return fail(error);
    }
}
