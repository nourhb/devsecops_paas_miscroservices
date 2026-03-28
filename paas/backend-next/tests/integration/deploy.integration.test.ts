import { prisma } from "../../src/lib/prisma";
import { POST as deployRoute } from "../../src/app/api/deploy/route";

describe("One-click deployment (real infra)", () => {
  it("triggers a deployment and returns deployment status", async () => {
    const project = await prisma.project.create({
      data: {
        name: "demo-deploy",
        gitRepo: "https://github.com/example/demo-deploy.git",
        registryRepo: "harbor.example.com/demo/deploy",
        ownerId: "user-1",
      },
    });

    const body = {
      projectId: project.id,
      branch: "main",
      commitSha: "abc123",
      namespace: "demo",
    };

    const req = new Request("http://localhost/api/deploy", {
      method: "POST",
      body: JSON.stringify(body),
    });

    const res = await deployRoute(req as any);
    expect(res.status).toBe(202);

    const json = await res.json();
    expect(json.deploymentId).toBeDefined();
    expect(json.imageTag).toBe("abc123");
    expect(json.argoApplication).toBe(`project-${project.id}`);

    const deployment = await prisma.deployment.findUnique({
      where: { id: json.deploymentId },
    });
    expect(deployment).not.toBeNull();
    expect(deployment?.projectId).toBe(project.id);
  });
});

