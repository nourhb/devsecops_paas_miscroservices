import { NextResponse } from "next/server";
import { z } from "zod";
import { prisma } from "../../../lib/prisma";
import { triggerPipeline } from "../../../lib/services/jenkins";
export const dynamic = "force-dynamic";
const triggerSchema = z.object({
    projectId: z.string().min(1),
    branch: z.string().default("main"),
    gitCommit: z.string().optional(),
});
export async function POST(req: Request) {
    const json = await req.json();
    const parsed = triggerSchema.safeParse(json);
    if (!parsed.success) {
        return NextResponse.json({ error: parsed.error.message }, { status: 400 });
    }
    const { projectId, branch, gitCommit } = parsed.data;
    const project = await prisma.project.findUnique({ where: { id: projectId } });
    if (!project) {
        return NextResponse.json({ error: "Project not found" }, { status: 404 });
    }
    const pipeline = await prisma.pipeline.create({
        data: {
            projectId,
            status: "QUEUED",
            commitSha: gitCommit ?? null,
        },
    });
    const jenkinsResult = await triggerPipeline({
        projectId,
        branch,
        gitRepoUrl: project.gitRepo,
        gitCommit,
    });
    await prisma.pipeline.update({
        where: { id: pipeline.id },
        data: {
            status: jenkinsResult.status,
            buildNumber: jenkinsResult.buildNumber ?? null,
        },
    });
    return NextResponse.json({ pipelineId: pipeline.id, ...jenkinsResult }, { status: 202 });
}
const statusQuerySchema = z.object({
    projectId: z.string().optional(),
});
export async function GET(req: Request) {
    const { searchParams } = new URL(req.url);
    const parsed = statusQuerySchema.safeParse({
        projectId: searchParams.get("projectId") ?? undefined,
    });
    if (!parsed.success) {
        return NextResponse.json({ error: parsed.error.message }, { status: 400 });
    }
    const where = parsed.data.projectId
        ? { projectId: parsed.data.projectId }
        : {};
    const pipelines = await prisma.pipeline.findMany({
        where,
        orderBy: { createdAt: "desc" },
        take: 50,
    });
    return NextResponse.json(pipelines);
}
