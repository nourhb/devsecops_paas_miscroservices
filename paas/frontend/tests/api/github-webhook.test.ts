import crypto from "node:crypto";
import { NextRequest } from "next/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("@/server/db/prisma", async () => {
    const { createPrismaMock } = await import("./mocks/prisma-state");
    return { prisma: createPrismaMock() };
});
const triggerBuildMock = vi.fn().mockResolvedValue({ status: "SUCCESS", message: "ok" });
vi.mock("@/server/pipeline/pipeline-service", () => ({
    triggerBuild: (...args: unknown[]) => triggerBuildMock(...args)
}));
import { POST as githubWebhookPost } from "@/app/api/webhooks/github/route";
import { seedDefaultProject } from "./mocks/prisma-state";
function sign(body: string): string {
    const secret = process.env.GITHUB_WEBHOOK_SECRET || "";
    const hex = crypto.createHmac("sha256", secret).update(body).digest("hex");
    return `sha256=${hex}`;
}
describe("POST /api/webhooks/github", () => {
    beforeEach(() => {
        seedDefaultProject();
        triggerBuildMock.mockClear();
    });
    it("accepts push event with valid signature and triggers build", async () => {
        const payload = {
            ref: "refs/heads/main",
            after: "abc123",
            repository: {
                clone_url: "https://github.com/org/repo.git",
                full_name: "org/repo"
            },
            pusher: { name: "dev", email: "dev@example.com" }
        };
        const body = JSON.stringify(payload);
        const req = new NextRequest("http://localhost/api/webhooks/github", {
            method: "POST",
            headers: {
                "content-type": "application/json",
                "x-github-event": "push",
                "x-hub-signature-256": sign(body)
            },
            body
        });
        const res = await githubWebhookPost(req);
        expect(res.status).toBe(200);
        const json = (await res.json()) as {
            status?: string;
            results?: unknown[];
        };
        expect(json.status).toBe("SUCCESS");
        expect(triggerBuildMock).toHaveBeenCalledTimes(1);
    });
    it("rejects invalid signature", async () => {
        const body = JSON.stringify({
            ref: "refs/heads/main",
            repository: { clone_url: "https://github.com/org/repo.git" }
        });
        const req = new NextRequest("http://localhost/api/webhooks/github", {
            method: "POST",
            headers: {
                "content-type": "application/json",
                "x-github-event": "push",
                "x-hub-signature-256": "sha256=deadbeef"
            },
            body
        });
        const res = await githubWebhookPost(req);
        expect(res.status).toBeGreaterThanOrEqual(400);
        expect(triggerBuildMock).toHaveBeenCalledTimes(0);
    });
});
