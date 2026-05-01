import { NextResponse } from "next/server";
import { prisma } from "../../../lib/prisma";
export const dynamic = "force-dynamic";
export async function GET() {
    const scanResults = await prisma.scanResult.findMany({
        orderBy: { id: "desc" },
        take: 100,
        include: {
            pipeline: {
                include: {
                    project: true,
                },
            },
        },
    });
    return NextResponse.json(scanResults.map((s: any) => ({
        id: s.id,
        scanner: s.scanner,
        severity: s.severity,
        reportUrl: s.reportUrl,
        pipelineId: s.pipelineId,
        projectId: s.pipeline.projectId,
        projectName: s.pipeline.project.name,
        createdAt: s.pipeline.createdAt,
    })));
}
