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
    return NextResponse.json({ cpu: 0.12, memory: 0.35, pods: 3 });
}
