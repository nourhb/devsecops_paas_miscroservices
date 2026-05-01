import { getProjectById } from "@/server/projects/project-service";
import { argoCdClient } from "@/server/integrations/devsecops-clients";
export async function getArgoStatusForProject(projectId: string) {
    const project = await getProjectById(projectId);
    return argoCdClient.applicationStatus(project.projectName);
}
