import { randomUUID } from "node:crypto";
import http from "node:http";
import { NextRequest } from "next/server";
import request from "supertest";
import { afterAll, beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("@/server/db/prisma", async () => {
    const { createPrismaMock } = await import("./mocks/prisma-state");
    return { prisma: createPrismaMock() };
});
vi.mock("@/server/services/jenkins-monitor", () => ({
    monitorDeployment: vi.fn()
}));
vi.mock("@/server/integrations/devsecops-clients", () => ({
    jenkinsClient: {
        getLastBuildSummary: vi.fn().mockResolvedValue(null),
        triggerDeployJob: vi.fn().mockResolvedValue({
            ok: true,
            buildNumber: 42,
            buildLog: "[jenkins] mocked deploy trigger and console tail",
            jobUrl: "http://jenkins.test/job/demo"
        })
    }
}));
vi.mock("@/server/gitops/gitops-github-service", () => ({
    commitHelmValuesGitHub: vi.fn().mockResolvedValue({ committed: true, ref: "mock-git-sha" })
}));
vi.mock("@/server/services/argocd-service", () => ({
    syncArgoApplication: vi.fn().mockResolvedValue({ logs: "[argocd] mock sync accepted" })
}));
import { POST as deployPost } from "@/app/api/deploy/[projectId]/route";
import { GET as deploymentGet } from "@/app/api/deployments/[id]/route";
import { GET as healthGet } from "@/app/api/health/route";
import { GET as readinessGet } from "@/app/api/platform/deploy-readiness/route";
import { signToken } from "@/server/security/jwt";
import { dbState, seedDefaultProject } from "./mocks/prisma-state";
function bearer(role: "ADMIN" | "DEVELOPER" = "ADMIN") {
    const token = signToken({ userId: "u1", email: "api-test@example.com", role });
    return { authorization: `Bearer ${token}` };
}
describe("POST /api/deploy/[projectId]", () => {
    beforeEach(() => {
        seedDefaultProject();
        vi.clearAllMocks();
    });
    it("returns 200, deploymentId, and creates a deployment row", async () => {
        const req = new NextRequest("http://localhost/api/deploy/p1", {
            method: "POST",
            headers: bearer()
        });
        const res = await deployPost(req, { params: { projectId: "p1" } });
        expect(res.status).toBe(200);
        const body = (await res.json()) as {
            deploymentId?: string;
            status?: string;
        };
        expect(body.deploymentId).toBeTruthy();
        expect(typeof body.deploymentId).toBe("string");
        expect(dbState.deployments).toHaveLength(1);
        expect(dbState.deployments[0].id).toBe(body.deploymentId);
    });
});
describe("GET /api/deployments/[id]", () => {
    beforeEach(() => {
        seedDefaultProject();
        vi.clearAllMocks();
    });
    it("returns deployment with status and logs", async () => {
        const postReq = new NextRequest("http://localhost/api/deploy/p1", {
            method: "POST",
            headers: bearer()
        });
        const postRes = await deployPost(postReq, { params: { projectId: "p1" } });
        const { deploymentId } = (await postRes.json()) as {
            deploymentId: string;
        };
        const getReq = new NextRequest(`http://localhost/api/deployments/${deploymentId}`, {
            headers: bearer()
        });
        const getRes = await deploymentGet(getReq, { params: { id: deploymentId } });
        expect(getRes.status).toBe(200);
        const payload = (await getRes.json()) as {
            id: string;
            status: string;
            logs: string;
        };
        expect(payload.id).toBe(deploymentId);
        expect(payload.status).toBeTruthy();
        expect(typeof payload.logs).toBe("string");
        expect(payload.logs.length).toBeGreaterThan(0);
    });
    it("returns 404 for unknown deployment id", async () => {
        const getReq = new NextRequest(`http://localhost/api/deployments/${randomUUID()}`, {
            headers: bearer()
        });
        const getRes = await deploymentGet(getReq, { params: { id: randomUUID() } });
        expect(getRes.status).toBe(404);
    });
});
describe("GET /api/platform/deploy-readiness", () => {
    it("returns integration flags and does not throw (simulation on in test env)", async () => {
        const req = new NextRequest("http://localhost/api/platform/deploy-readiness", {
            headers: bearer()
        });
        const res = await readinessGet(req);
        expect(res.status).toBe(200);
        const data = (await res.json()) as {
            jenkins: {
                configured: boolean;
            };
            gitops: {
                configured: boolean;
            };
            argocd: {
                configured: boolean;
            };
            simulationEnabled: boolean;
            missingForFullPipeline: string[];
        };
        expect(data.jenkins).toBeDefined();
        expect(data.gitops).toBeDefined();
        expect(data.argocd).toBeDefined();
        expect(data.simulationEnabled).toBe(true);
        expect(Array.isArray(data.missingForFullPipeline)).toBe(true);
    });
});
describe("supertest (health bridge)", () => {
    const server = http.createServer(async (_req, res) => {
        const r = await healthGet();
        res.statusCode = r.status;
        const ct = r.headers.get("content-type");
        if (ct) {
            res.setHeader("content-type", ct);
        }
        res.end(await r.text());
    });
    afterAll(() => new Promise<void>((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()));
    }));
    it("returns JSON body via HTTP", async () => {
        await new Promise<void>((resolve, reject) => {
            server.listen(0, () => resolve());
            server.on("error", reject);
        });
        const res = await request(server).get("/").expect(200);
        expect(res.body.ok).toBe(true);
        expect(res.body.service).toBe("paas-frontend");
    });
});
