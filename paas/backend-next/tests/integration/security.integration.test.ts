import { prisma } from "../../src/lib/prisma";
import { runImageScan } from "../../src/lib/services/trivy";
import { GET as securityRoute } from "../../src/app/api/security/route";

jest.mock("node:child_process", () => {
  return {
    exec: (
      _cmd: string,
      cb: (err: null, stdout: string, stderr: string) => void,
    ) => {
      const fake = JSON.stringify({
        Results: [
          {
            Target: "image",
            Vulnerabilities: [
              { ID: "CVE-1", Severity: "CRITICAL" },
              { ID: "CVE-2", Severity: "HIGH" },
            ],
          },
        ],
      });
      cb(null, fake, "");
    },
  };
});

describe("Security scan storage", () => {
  it("stores Trivy results and exposes them via /api/security", async () => {
    const project = await prisma.project.create({
      data: {
        name: "sec-app",
        gitRepo: "https://github.com/example/sec-app.git",
        registryRepo: "harbor.example.com/sec/app",
        ownerId: "user-1",
      },
    });

    const pipeline = await prisma.pipeline.create({
      data: {
        projectId: project.id,
        status: "SUCCESS",
      },
    });

    const result = await runImageScan(pipeline.id, "harbor.example.com/sec/app:latest");
    expect(result.ok).toBe(true);

    const scan = await prisma.scanResult.findFirst({
      where: { pipelineId: pipeline.id, scanner: "trivy" },
    });
    expect(scan).not.toBeNull();
    expect(scan?.severity).toContain("CRITICAL");

    const res = await securityRoute();
    expect(res.status).toBe(200);
    const json = await res.json();
    expect(Array.isArray(json)).toBe(true);
    expect(json[0].scanner).toBe("trivy");
  });
});

