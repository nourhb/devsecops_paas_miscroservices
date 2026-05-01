import crypto from "crypto";
import { prisma } from "@/server/db/prisma";
import { env } from "@/server/config/env";
import { enforceRateLimit } from "@/server/http/rate-limit";
import { ok, fail } from "@/server/http/response";
import { IntegrationError } from "@/server/http/errors";
import { writeAuditLog } from "@/server/audit/audit-log";
import { normalizeGitUrl } from "@/server/github/normalize-git-url";
import { triggerBuild } from "@/server/pipeline/pipeline-service";
import type { NextRequest } from "next/server";
export const runtime = "nodejs";
function timingSafeEqualHex(a: string, b: string): boolean {
    const aa = Buffer.from(a, "hex");
    const bb = Buffer.from(b, "hex");
    if (aa.length !== bb.length) {
        return false;
    }
    return crypto.timingSafeEqual(aa, bb);
}
function verifyGitHubSignature(rawBody: Buffer, signatureHeader: string | null): void {
    const secret = env.GITHUB_WEBHOOK_SECRET?.trim();
    if (!secret) {
        throw new IntegrationError("GitHub webhook is not configured: set GITHUB_WEBHOOK_SECRET on the PaaS server.");
    }
    const sig = (signatureHeader || "").trim();
    if (!sig.startsWith("sha256=")) {
        throw new IntegrationError("Invalid GitHub signature header (expected X-Hub-Signature-256).");
    }
    const expected = crypto.createHmac("sha256", secret).update(rawBody).digest("hex");
    const given = sig.slice("sha256=".length);
    if (!timingSafeEqualHex(expected, given)) {
        throw new IntegrationError("GitHub webhook signature verification failed.");
    }
}
type GitHubPushEvent = {
    ref?: string;
    after?: string;
    repository?: {
        clone_url?: string;
        html_url?: string;
        ssh_url?: string;
        full_name?: string;
    };
    pusher?: {
        name?: string;
        email?: string;
    };
};
export async function POST(request: NextRequest) {
    try {
        enforceRateLimit(request, {
            keyPrefix: "webhook:github",
            windowMs: 60000,
            maxRequests: 60,
            message: "Too many webhook requests. Please retry later."
        });
        const event = request.headers.get("x-github-event") || "";
        const signature = request.headers.get("x-hub-signature-256");
        const bodyText = await request.text();
        const rawBody = Buffer.from(bodyText, "utf8");
        verifyGitHubSignature(rawBody, signature);
        if (event === "ping") {
            return ok({ status: "SUCCESS", message: "pong" });
        }
        if (event !== "push") {
            return ok({ status: "SUCCESS", message: `ignored ${event}` });
        }
        const payload = JSON.parse(bodyText) as GitHubPushEvent;
        const ref = payload.ref || "";
        const branch = ref.startsWith("refs/heads/") ? ref.slice("refs/heads/".length) : "";
        const repoUrlRaw = payload.repository?.clone_url ||
            payload.repository?.html_url ||
            payload.repository?.ssh_url ||
            "";
        const repoUrl = normalizeGitUrl(repoUrlRaw);
        if (!repoUrl) {
            throw new IntegrationError("GitHub push payload missing repository URL.");
        }
        const projects = await prisma.project.findMany({
            where: { deletedAt: null }
        });
        const matches = projects.filter((p) => normalizeGitUrl(p.gitRepositoryUrl) === repoUrl);
        if (matches.length === 0) {
            return ok({ status: "SUCCESS", message: `no project matched ${repoUrl}` });
        }
        const toTrigger = matches.filter((p) => {
            const configured = (p.branch || "").trim();
            if (!configured) {
                return true;
            }
            if (!branch) {
                return true;
            }
            return configured === branch;
        });
        if (toTrigger.length === 0) {
            return ok({ status: "SUCCESS", message: `no branch match for ${repoUrl} (${branch || "unknown"})` });
        }
        const results: Array<{
            projectId: string;
            projectName: string;
        }> = [];
        for (const project of toTrigger) {
            await triggerBuild(project.id);
            results.push({ projectId: project.id, projectName: project.projectName });
            writeAuditLog({
                action: "webhook.github.push.build.trigger",
                outcome: "success",
                actorEmail: payload.pusher?.email || payload.pusher?.name || "github",
                targetType: "project",
                targetId: project.id,
                metadata: {
                    repo: repoUrl,
                    branch,
                    after: payload.after || "",
                    githubProject: payload.repository?.full_name || ""
                }
            });
        }
        return ok({
            status: "SUCCESS",
            message: `Triggered build for ${results.length} project(s)`,
            results
        });
    }
    catch (error) {
        return fail(error);
    }
}
