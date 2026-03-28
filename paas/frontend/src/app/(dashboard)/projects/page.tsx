"use client";

import Link from "next/link";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { projectApi } from "@/lib/api";
import type { Project } from "@/types";

export default function ProjectsPage() {
  const queryClient = useQueryClient();

  const projectsQuery = useQuery({
    queryKey: ["projects"],
    queryFn: projectApi.getProjects
  });

  const deleteMutation = useMutation({
    mutationFn: projectApi.deleteProject,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["projects"] });
      toast.success("Project deleted");
    },
    onError: (err: unknown) => {
      const message = err instanceof Error ? err.message : "Could not delete project";
      toast.error(message);
    }
  });

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="text-2xl font-semibold">Projects</h2>
          <p className="text-sm text-muted">Git-backed services with CI/CD, security scans, and deployments.</p>
        </div>
        <Button asChild>
          <Link href="/projects/create">Create project</Link>
        </Button>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>All projects</CardTitle>
        </CardHeader>
        <CardContent>
          {projectsQuery.isLoading ? (
            <div className="space-y-2">
              <Skeleton className="h-10 w-full" />
              <Skeleton className="h-10 w-full" />
              <Skeleton className="h-10 w-full" />
            </div>
          ) : projectsQuery.isError ? (
            <p className="text-sm text-danger">Failed to load projects. Check your session and API.</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Name</TableHead>
                  <TableHead>Git</TableHead>
                  <TableHead>Branch</TableHead>
                  <TableHead>Build</TableHead>
                  <TableHead>Deploy</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {(projectsQuery.data ?? []).map((p: Project) => (
                  <TableRow key={p.id}>
                    <TableCell className="font-medium">{p.projectName}</TableCell>
                    <TableCell className="max-w-[200px] truncate font-mono text-xs text-muted">
                      {p.gitRepositoryUrl}
                    </TableCell>
                    <TableCell>{p.branch}</TableCell>
                    <TableCell>
                      <Badge variant={p.buildStatus === "SUCCESS" ? "success" : "warning"}>{p.buildStatus}</Badge>
                    </TableCell>
                    <TableCell>
                      <Badge variant={p.lastDeploymentStatus === "SUCCESS" ? "success" : "outline"}>
                        {p.lastDeploymentStatus}
                      </Badge>
                    </TableCell>
                    <TableCell className="text-right">
                      <div className="flex flex-wrap justify-end gap-2">
                        <Button size="sm" variant="outline" asChild>
                          <Link href={`/projects/${p.id}`}>Details</Link>
                        </Button>
                        <Button size="sm" variant="outline" asChild>
                          <Link href={`/pipeline/${p.id}`}>Pipeline</Link>
                        </Button>
                        <Button size="sm" variant="outline" asChild>
                          <Link href={`/docker/${p.id}`}>Docker</Link>
                        </Button>
                        <Button size="sm" variant="outline" asChild>
                          <Link href={`/security/${p.id}`}>Security</Link>
                        </Button>
                        <Button size="sm" variant="outline" asChild>
                          <Link href={`/monitoring/${p.id}`}>Monitoring</Link>
                        </Button>
                        <Button size="sm" variant="outline" asChild>
                          <Link href={`/projects/${p.id}/edit`}>Edit</Link>
                        </Button>
                        <Button
                          size="sm"
                          variant="destructive"
                          disabled={deleteMutation.isPending}
                          onClick={() => {
                            if (confirm(`Delete project "${p.projectName}"?`)) {
                              deleteMutation.mutate(p.id);
                            }
                          }}
                        >
                          Delete
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
          {!projectsQuery.isLoading && (projectsQuery.data?.length ?? 0) === 0 ? (
            <p className="py-8 text-center text-sm text-muted">No projects yet. Create one to connect a repository.</p>
          ) : null}
        </CardContent>
      </Card>
    </div>
  );
}
