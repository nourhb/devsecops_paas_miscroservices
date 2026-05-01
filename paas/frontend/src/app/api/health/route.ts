import { NextResponse } from "next/server";
import { env } from "@/server/config/env";
import { prisma } from "@/server/db/prisma";
import { getDeployPipelineReadiness } from "@/server/services/deploy-pipeline-readiness";
export const runtime = "nodejs";
export async function GET() {
    let database = {
        connected: false as boolean,
        error: "" as string
    };
    try {
        await prisma.$queryRawUnsafe("SELECT 1");
        database = { connected: true, error: "" };
    }
    catch (error) {
        database = {
            connected: false,
            error: error instanceof Error ? error.message : "Database query failed"
        };
    }
    const readiness = getDeployPipelineReadiness();
    const ok = database.connected && readiness.missingForFullPipeline.length === 0;
    return NextResponse.json({
        ok,
        service: "paas-frontend",
        timestamp: new Date().toISOString(),
        database,
        integrations: {
            buildBackend: readiness.buildBackend,
            jenkinsConfigured: readiness.jenkins.configured,
            gitopsConfigured: readiness.gitops.configured,
            argocdConfigured: readiness.argocd.configured,
            appsPublicUrlConfigured: readiness.appsPublicUrl.configured,
            simulationEnabled: readiness.simulationEnabled
        },
        requiredConfig: {
            appBaseUrl: Boolean(env.APP_BASE_URL.trim()),
            jwtConfigured: env.JWT_SECRET !== "change-this-dev-secret-to-32-char-min"
        }
    }, { status: ok ? 200 : 503 });
}
