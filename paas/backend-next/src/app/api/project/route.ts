import { NextResponse } from "next/server";
import { z } from "zod";
import { prisma } from "../../../lib/prisma";
import { upsertApplication, deleteApplication } from "../../../lib/services/argocd";
import { createRepository, deleteRepository } from "../../../lib/services/harbor";
import { createPipelineJob, deleteJob, } from "../../../lib/services/jenkins";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { exec } from "node:child_process";
import { promisify } from "node:util";
export const dynamic = "force-dynamic";
const execAsync = promisify(exec);
const bodySchema = z.object({
    name: z.string().min(1),
    gitRepo: z.string().url(),
    registryRepo: z.string().min(1),
    ownerId: z.string().min(1),
    namespace: z.string().default("default"),
});
export async function POST(req: Request) {
    const json = await req.json();
    const parsed = bodySchema.safeParse(json);
    if (!parsed.success) {
        return NextResponse.json({ error: parsed.error.message }, { status: 400 });
    }
    const data = parsed.data;
    let projectId: string | null = null;
    let harborProject: string | null = null;
    let harborRepo: string | null = null;
    let gitopsTempDir: string | null = null;
    let argocdAppName: string | null = null;
    let jenkinsJobName: string | null = null;
    try {
        const project = await prisma.project.create({
            data: {
                name: data.name,
                gitRepo: data.gitRepo,
                registryRepo: data.registryRepo,
                ownerId: data.ownerId,
            },
        });
        projectId = project.id;
        const appName = `project-${project.id}`;
        argocdAppName = appName;
        jenkinsJobName = appName;
        const withoutRegistry = project.registryRepo.split("/").slice(1).join("/");
        const [projectAndRepo] = withoutRegistry.split(":");
        const [hp, ...repoParts] = projectAndRepo.split("/");
        harborProject = hp;
        harborRepo = repoParts.join("/") || data.name;
        if (!harborProject || !harborRepo) {
            throw new Error("Unable to derive Harbor project/repository from registryRepo.");
        }
        await createRepository(harborProject, harborRepo);
        const gitopsRepoUrl = process.env.GITOPS_REPO_URL;
        if (!gitopsRepoUrl) {
            throw new Error("GITOPS_REPO_URL is not configured.");
        }
        const branch = process.env.GITOPS_BRANCH || "main";
        gitopsTempDir = fs.mkdtempSync(path.join(os.tmpdir(), "gitops-provision-"));
        await execAsync(`git clone --branch ${branch} ${gitopsRepoUrl} .`, {
            cwd: gitopsTempDir,
        });
        const srcChartDir = path.join(gitopsTempDir, "apps", "sample-app");
        const destChartDir = path.join(gitopsTempDir, "apps", project.name);
        if (!fs.existsSync(srcChartDir)) {
            throw new Error("Sample Helm chart not found in GitOps repo (apps/sample-app).");
        }
        if (!fs.existsSync(destChartDir)) {
            fs.mkdirSync(destChartDir, { recursive: true });
            for (const file of fs.readdirSync(srcChartDir, { withFileTypes: true })) {
                const srcPath = path.join(srcChartDir, file.name);
                const destPath = path.join(destChartDir, file.name);
                if (file.isDirectory()) {
                    fs.mkdirSync(destPath, { recursive: true });
                    for (const nested of fs.readdirSync(srcPath)) {
                        const nestedSrc = path.join(srcPath, nested);
                        const nestedDest = path.join(destPath, nested);
                        const content = fs.readFileSync(nestedSrc, "utf8")
                            .replace(/sample-app/g, project.name)
                            .replace(/harbor\.example\.com\/project\/image/g, project.registryRepo);
                        fs.writeFileSync(nestedDest, content);
                    }
                }
                else {
                    const content = fs.readFileSync(srcPath, "utf8")
                        .replace(/sample-app/g, project.name)
                        .replace(/harbor\.example\.com\/project\/image/g, project.registryRepo);
                    fs.writeFileSync(destPath, content);
                }
            }
        }
        await execAsync("git add .", { cwd: gitopsTempDir });
        await execAsync(`git commit -m "Add app ${project.name} from DevSecOps PaaS"`, { cwd: gitopsTempDir }).catch(() => undefined);
        await execAsync(`git push origin ${branch}`, { cwd: gitopsTempDir });
        await upsertApplication({
            name: appName,
            project: "default",
            repoUrl: gitopsRepoUrl,
            targetRevision: branch,
            path: `apps/${project.name}`,
            namespace: data.namespace,
        });
        await createPipelineJob(jenkinsJobName, project.gitRepo);
        return NextResponse.json({
            projectId: project.id,
            project,
            jenkinsJob: jenkinsJobName,
            harborRepository: harborProject && harborRepo
                ? `${harborProject}/${harborRepo}`
                : null,
            argocdApplication: argocdAppName,
        }, { status: 201 });
    }
    catch (error) {
        if (argocdAppName) {
            await deleteApplication(argocdAppName).catch(() => undefined);
        }
        if (jenkinsJobName) {
            await deleteJob(jenkinsJobName).catch(() => undefined);
        }
        if (harborProject && harborRepo) {
            await deleteRepository(harborProject, harborRepo).catch(() => undefined);
        }
        if (projectId) {
            await prisma.project.delete({ where: { id: projectId } }).catch(() => undefined);
        }
        if (gitopsTempDir && fs.existsSync(gitopsTempDir)) {
            fs.rmSync(gitopsTempDir, { recursive: true, force: true });
        }
        const message = (error as Error).message;
        return NextResponse.json({ error: message }, { status: 500 });
    }
}
export async function GET() {
    const projects = await prisma.project.findMany({
        orderBy: { createdAt: "desc" },
    });
    return NextResponse.json(projects);
}
