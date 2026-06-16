"use client";
import { usePathname } from "next/navigation";
import { useQuery } from "@tanstack/react-query";
import { pipelineApi } from "@/lib/api";
import { resolveDeploymentIdFromPath, resolveProjectIdFromPath } from "@/lib/resolve-project-id-from-path";

export function useProjectIdFromRoute(): string | null {
    const pathname = usePathname() ?? "";
    const projectIdFromPath = resolveProjectIdFromPath(pathname);
    const deploymentId = resolveDeploymentIdFromPath(pathname);
    const deploymentQuery = useQuery({
        queryKey: ["deployment", deploymentId],
        queryFn: () => pipelineApi.getDeployment(deploymentId!),
        enabled: Boolean(deploymentId) && !projectIdFromPath,
        staleTime: 60_000
    });
    return projectIdFromPath ?? deploymentQuery.data?.projectId ?? null;
}
