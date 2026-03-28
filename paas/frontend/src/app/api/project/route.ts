import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { createProject, listProjects } from "@/server/projects/project-service";
import { created, fail, ok } from "@/server/http/response";
import { jenkinsClient } from "@/server/integrations/devsecops-clients";

export const runtime = "nodejs";

export async function GET(request: NextRequest) {
  try {
    const auth = requireAuth(request, ["ADMIN", "DEVELOPER"]);
    const projects = await listProjects(auth.userId, auth.role);
    return ok(projects);
  } catch (error) {
    return fail(error);
  }
}

export async function POST(request: NextRequest) {
  try {
    const auth = requireAuth(request, ["ADMIN", "DEVELOPER"]);
    const body = await request.json();
    const project = await createProject(body, auth.userId);
    await jenkinsClient.createPipeline(project.projectName);
    return created(project);
  } catch (error) {
    return fail(error);
  }
}
