import { NextResponse } from "next/server";
import { z } from "zod";
import { prisma } from "../../../lib/prisma";
import { triggerPipeline } from "../../../lib/services/jenkins";

export const dynamic = "force-dynamic";

const bodySchema = z.object({
  projectId: z.string().min(1),
  branch: z.string().default("main"),
  commitSha: z.string().optional(),
  namespace: z.string().default("default"),
});

export async function POST(req: Request) {
  const json = await req.json();
  const parsed = bodySchema.safeParse(json);

  if (!parsed.success) {
    return NextResponse.json(
      { error: parsed.error.message },
      { status: 400 },
    );
  }

  const { projectId, branch, commitSha, namespace } = parsed.data;

  try {
    const project = await prisma.project.findUnique({
      where: { id: projectId },
    });

    if (!project) {
      return NextResponse.json(
        { error: "Project not found" },
        { status: 404 },
      );
    }

    // Create pipeline record
    const pipeline = await prisma.pipeline.create({
      data: {
        projectId,
        status: "QUEUED",
        commitSha: commitSha ?? null,
      },
    });

    // Trigger Jenkins pipeline (build, scan, sign, push, GitOps update)
    await triggerPipeline({
      projectId,
      branch,
      gitRepoUrl: project.gitRepo,
      gitCommit: commitSha,
    });

    // Create deployment record (ArgoCD will sync after GitOps update)
    const imageTag = commitSha ?? "latest";

    const deployment = await prisma.deployment.create({
      data: {
        projectId,
        imageTag,
        namespace,
        status: "PENDING",
      },
    });

    const argoApplication = `project-${project.id}`;

    return NextResponse.json(
      {
        deploymentId: deployment.id,
        pipelineBuild: pipeline.buildNumber, // may be null until Jenkins reports back
        imageTag,
        argoApplication,
      },
      { status: 202 },
    );
  } catch (error) {
    const message = (error as Error).message;
    return NextResponse.json(
      { error: message },
      { status: 500 },
    );
  }
}

