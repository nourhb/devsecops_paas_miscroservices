import type { QueryClient } from "@tanstack/react-query";

export function invalidatePostDeployQueries(queryClient: QueryClient, projectId: string): void {
    void queryClient.invalidateQueries({ queryKey: ["dashboard-overview"] });
    void queryClient.invalidateQueries({ queryKey: ["security", projectId] });
    void queryClient.invalidateQueries({ queryKey: ["dependency-track", projectId] });
    void queryClient.invalidateQueries({ queryKey: ["jenkins-pipeline-stages", projectId] });
    void queryClient.invalidateQueries({ queryKey: ["project", projectId] });
    void queryClient.invalidateQueries({ queryKey: ["status", projectId] });
    void queryClient.invalidateQueries({ queryKey: ["deployments", projectId] });
}
