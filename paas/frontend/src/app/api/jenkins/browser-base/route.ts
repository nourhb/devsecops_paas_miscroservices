import { NextRequest } from "next/server";
import { env } from "@/server/config/env";
import { ok } from "@/server/http/response";
export async function GET(_request: NextRequest) {
    const base = (env.JENKINS_PROBE_URL || "").trim().replace(/\/+$/, "")
        || (env.JENKINS_BASE_URL.includes(".svc.cluster.local")
            ? `http://${env.APPS_PUBLIC_LAB_NODE_IP || "192.168.56.129"}:30090`
            : env.JENKINS_BASE_URL.replace(/\/+$/, ""));
    return ok({ baseUrl: base || null });
}
