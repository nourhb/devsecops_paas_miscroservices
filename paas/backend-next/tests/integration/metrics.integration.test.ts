import { prisma } from "../../src/lib/prisma";
import { GET as metricsRoute } from "../../src/app/api/metrics/route";

describe("Monitoring endpoint", () => {
  it("returns cluster, pipeline, deployment and security data", async () => {
    const project = await prisma.project.create({
      data: {
        name: "metrics-app",
        gitRepo: "https://github.com/example/metrics-app.git",
        registryRepo: "harbor.example.com/metrics/app",
        ownerId: "user-1",
      },
    });

    await prisma.pipeline.create({
      data: {
        projectId: project.id,
        status: "SUCCESS",
        buildNumber: 1,
      },
    });

    await prisma.deployment.create({
      data: {
        projectId: project.id,
        imageTag: "latest",
        namespace: "default",
        status: "SUCCESS",
      },
    });

    await prisma.scanResult.create({
      data: {
        pipelineId: (await prisma.pipeline.findFirstOrThrow()).id,
        scanner: "trivy",
        severity: "NONE",
        reportUrl: null,
      },
    });

    const res = await metricsRoute();
    expect(res.status).toBe(200);

    const json = await res.json();
    expect(json.cluster).toBeDefined();
    expect(Array.isArray(json.pipelines)).toBe(true);
    expect(json.deployments).toBeDefined();
    expect(json.security).toBeDefined();
  });
});

