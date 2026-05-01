"use client";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { dockerApi, projectApi } from "@/lib/api";
import type { ContainerImageRecord } from "@/types";
export default function DockerPage() {
    const params = useParams<{
        id: string;
    }>();
    const projectId = params.id;
    const queryClient = useQueryClient();
    const projectQuery = useQuery({
        queryKey: ["project", projectId],
        queryFn: () => projectApi.getProject(projectId)
    });
    const historyQuery = useQuery({
        queryKey: ["docker-history", projectId],
        queryFn: () => dockerApi.history(projectId),
        refetchInterval: 15000
    });
    const buildMutation = useMutation({
        mutationFn: () => dockerApi.build(projectId),
        onSuccess: (data) => {
            queryClient.invalidateQueries({ queryKey: ["docker-history", projectId] });
            queryClient.invalidateQueries({ queryKey: ["project", projectId] });
            toast.success(`Built ${data.imageRef}`);
        },
        onError: () => toast.error("Docker build failed")
    });
    const pushMutation = useMutation({
        mutationFn: () => dockerApi.push(projectId),
        onSuccess: (data) => {
            queryClient.invalidateQueries({ queryKey: ["docker-history", projectId] });
            toast.success(data.registryAuthOk ? `Pushed ${data.imageRef}` : `Simulated push: ${data.imageRef}`);
        },
        onError: () => toast.error("Docker push failed")
    });
    return (<div className="space-y-6">
      <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
        <div>
          <h2 className="text-2xl font-semibold">Docker &amp; registry</h2>
          {projectQuery.data ? (<p className="text-sm text-muted">
              Current tag:{" "}
              <span className="font-mono text-xs">{projectQuery.data.imageTag || "not set"}</span>
            </p>) : projectQuery.isLoading ? (<Skeleton className="mt-2 h-4 w-48"/>) : null}
        </div>
        <div className="flex flex-wrap gap-2">
          <Button onClick={() => buildMutation.mutate()} disabled={buildMutation.isPending}>
            {buildMutation.isPending ? "Building…" : "Build image"}
          </Button>
          <Button onClick={() => pushMutation.mutate()} disabled={pushMutation.isPending} variant="outline">
            {pushMutation.isPending ? "Pushing…" : "Push to Docker Hub"}
          </Button>
          <Button asChild variant="outline" size="sm">
            <Link href={`/pipeline/${projectId}`}>Pipeline</Link>
          </Button>
        </div>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Image history</CardTitle>
        </CardHeader>
        <CardContent>
          {historyQuery.isLoading ? (<Skeleton className="h-32 w-full"/>) : (<Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Time</TableHead>
                  <TableHead>Action</TableHead>
                  <TableHead>Registry</TableHead>
                  <TableHead>Reference</TableHead>
                  <TableHead>Digest</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {(historyQuery.data ?? []).map((row: ContainerImageRecord) => (<TableRow key={row.id}>
                    <TableCell className="whitespace-nowrap text-xs text-muted">
                      {new Date(row.createdAt).toLocaleString()}
                    </TableCell>
                    <TableCell>{row.action}</TableCell>
                    <TableCell>{row.registry}</TableCell>
                    <TableCell className="max-w-[220px] truncate font-mono text-xs">{row.imageRef}</TableCell>
                    <TableCell className="max-w-[140px] truncate font-mono text-xs">{row.digest ?? "—"}</TableCell>
                  </TableRow>))}
              </TableBody>
            </Table>)}
          {!historyQuery.isLoading && (historyQuery.data?.length ?? 0) === 0 ? (<p className="py-6 text-center text-sm text-muted">No images recorded yet. Run a build or push.</p>) : null}
        </CardContent>
      </Card>

      <p className="text-xs text-muted">
        Set <code className="rounded bg-muted/50 px-1">DOCKERHUB_USERNAME</code>,{" "}
        <code className="rounded bg-muted/50 px-1">DOCKERHUB_TOKEN</code>, and{" "}
        <code className="rounded bg-muted/50 px-1">DOCKERHUB_NAMESPACE</code> to verify registry credentials. Without
        them, pushes are simulated and still written to history for auditing.
      </p>
    </div>);
}
