import { NextResponse } from "next/server";
import { z } from "zod";
import { prisma } from "../../../lib/prisma";
import { syncApplication } from "../../../lib/services/argocd";
import { getDeploymentStatus } from "../../../lib/services/kubernetes";

export const dynamic = "force-dynamic";

const redeploySchema = z.object({
  projectId: z.string().min(1),
  imageTag: z.string().min(1),
  namespace: z.string().default("default"),
});

export async function GET(req: Request) {
  const { searchParams } = new URL(req.url);
  const projectId = searchParams.get("projectId") ?? undefined;

  const where = projectId ? { projectId } : {};
  const deployments = await prisma.deployment.findMany({
    where,
    orderBy: { createdAt: "desc" },
    take: 50,
  });

  return NextResponse.json(deployments);
}

export async function POST(req: Request) {
  const json = await req.json();
  const parsed = redeploySchema.safeParse(json);
  if (!parsed.success) {
    return NextResponse.json(
      { error: parsed.error.message },
      { status: 400 },
    );
  }

  const { projectId, imageTag, namespace } = parsed.data;

  const project = await prisma.project.findUnique({ where: { id: projectId } });
  if (!project) {
    return NextResponse.json({ error: "Project not found" }, { status: 404 });
  }

  const deployment = await prisma.deployment.create({
    data: {
      projectId,
      imageTag,
      namespace,
      status: "PENDING",
    },
  });

  const appName = `project-${project.id}`;
  await syncApplication(appName);

  const k8sStatus = await getDeploymentStatus(appName, namespace);

  const updated = await prisma.deployment.update({
    where: { id: deployment.id },
    data: {
      status: k8sStatus.ready ? "SUCCESS" : "IN_PROGRESS",
    },
  });

  return NextResponse.json(updated, { status: 202 });
}

