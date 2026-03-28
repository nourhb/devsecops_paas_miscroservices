import { prisma } from "../../src/lib/prisma";
import { POST as createProjectRoute } from "../../src/app/api/project/route";

describe("Project creation flow (real infra)", () => {
  it("creates a project and returns provisioning info", async () => {
    const body = {
      name: "demo-app",
      gitRepo: "https://github.com/example/demo-app.git",
      registryRepo: "harbor.example.com/demo/app",
      ownerId: "user-1",
      namespace: "demo",
    };

    const req = new Request("http://localhost/api/project", {
      method: "POST",
      body: JSON.stringify(body),
    });

    const res = await createProjectRoute(req as any);
    expect(res.status).toBe(201);

    const json = await res.json();
    expect(json.projectId).toBeDefined();
    expect(json.project).toBeDefined();
    expect(json.jenkinsJob).toContain("project-");
    expect(json.harborRepository).toBeTruthy();
    expect(json.argocdApplication).toContain("project-");

    const dbProject = await prisma.project.findUnique({
      where: { id: json.projectId },
    });
    expect(dbProject).not.toBeNull();
  });
});

