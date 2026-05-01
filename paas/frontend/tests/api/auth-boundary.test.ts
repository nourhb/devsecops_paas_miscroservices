import { NextRequest } from "next/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("@/server/integrations/kubernetes-client", () => ({
    listClusterPods: vi.fn(async () => ({
        configured: true,
        items: [],
        error: ""
    }))
}));
vi.mock("@/server/integrations/devsecops-clients", () => ({
    jenkinsClient: {
        listDashboardBuilds: vi.fn(async () => [])
    }
}));
vi.mock("@/server/ai/assistant", () => ({
    suggestBuildParametersWithAi: vi.fn(async () => ({
        projectName: "demo",
        buildType: "node",
        deliveryType: "docker"
    }))
}));
import { GET as getPods } from "@/app/api/k8s/pods/route";
import { GET as getJenkinsBuilds } from "@/app/api/jenkins/builds/route";
import { POST as postAiSuggest } from "@/app/api/ai/suggest/route";
import { signToken } from "@/server/security/jwt";
function bearer(role: "ADMIN" | "DEVELOPER" = "ADMIN") {
    const token = signToken({ userId: "u1", email: "boundary@example.com", role });
    return { authorization: `Bearer ${token}` };
}
describe("protected control plane routes", () => {
    beforeEach(() => {
        vi.clearAllMocks();
    });
    it("rejects unauthenticated Kubernetes pod access", async () => {
        const req = new NextRequest("http://localhost/api/k8s/pods");
        const res = await getPods(req);
        expect(res.status).toBe(401);
    });
    it("allows authenticated Kubernetes pod access", async () => {
        const req = new NextRequest("http://localhost/api/k8s/pods", {
            headers: bearer()
        });
        const res = await getPods(req);
        expect(res.status).toBe(200);
    });
    it("rejects unauthenticated Jenkins dashboard access", async () => {
        const req = new NextRequest("http://localhost/api/jenkins/builds?jobName=demo");
        const res = await getJenkinsBuilds(req);
        expect(res.status).toBe(401);
    });
    it("rejects unauthenticated AI suggestions", async () => {
        const req = new NextRequest("http://localhost/api/ai/suggest", {
            method: "POST",
            body: JSON.stringify({ prompt: "Build a Next.js app" })
        });
        const res = await postAiSuggest(req);
        expect(res.status).toBe(401);
    });
});
