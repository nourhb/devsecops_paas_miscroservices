import { NextResponse } from "next/server";
import { db } from "../../../../lib/in-memory-db";
export async function POST(req: Request, { params }: {
    params: {
        projectId: string;
    };
}) {
    const { projectId } = params;
    const project = db.projects.get(projectId);
    if (!project)
        return NextResponse.json({ error: "Not found" }, { status: 404 });
    return NextResponse.json({ status: "ROLLBACK_TRIGGERED", projectId });
}
