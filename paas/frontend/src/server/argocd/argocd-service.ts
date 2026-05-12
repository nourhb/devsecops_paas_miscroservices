import { getArgoApplicationStatus } from "@/server/services/argocd-service";
import { getProjectById } from "@/server/projects/project-service";
export async function getArgoStatusForProject(projectId: string) {
    const project = await getProjectById(projectId);
    return getArgoApplicationStatus(project.projectName);
}
