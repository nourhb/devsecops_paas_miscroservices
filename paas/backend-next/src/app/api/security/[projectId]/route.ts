import { NextResponse } from "next/server";
import { db } from "../../../../lib/in-memory-db";
export async function GET(req: Request, { params }: {
    params: {
        projectId: string;
    };
}) {
    const { projectId } = params;
    const project = db.projects.get(projectId);
    if (!project)
        return NextResponse.json({ error: "Not found" }, { status: 404 });
    return NextResponse.json({
        sonar: { status: "OK", qualityGate: "PASS" },
        trivy: { critical: 0, high: 1, medium: 2, low: 3 },
        cosign: { signed: true },
        opa: { violations: [] }
    });
}
