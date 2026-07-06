"use client";
// Next.js page UI for dashboard docker [id]
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
    const registryQuery = useQuery({
        queryKey: ["docker-registry-status"],
        queryFn: () => dockerApi.registryStatus(),
        staleTime: 60000
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
    const registry = registryQuery.data;
    return (<div className="space-y-6">
      <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
        <div>
          <h2 className="flex flex-wrap items-center gap-2 text-2xl font-semibold">
            Docker &amp; registry
          </h2>
          {projectQuery.data ? (<p className="text-sm text-muted">
              Current tag:{" "}
              <span className="font-mono text-xs">{projectQuery.data.imageTag || "not set"}</span>
            </p>) : projectQuery.isLoading ? (<Skeleton className="mt-2 h-4 w-48"/>) : null}
          {registry ? (<p className="text-sm text-muted">
              Registry:{" "}
              <span className={registry.verified ? "text-emerald-600" : registry.configured ? "text-amber-600" : "text-muted"}>
                {registry.registryLabel}
                {registry.configured ? (registry.verified ? " (verified)" : " (auth failed)") : ""}
              </span>
            </p>) : registryQuery.isLoading ? (<Skeleton className="mt-2 h-4 w-64"/>) : null}
        </div>
        <div className="flex flex-wrap gap-2">
          <Button onClick={() => buildMutation.mutate()} disabled={buildMutation.isPending}>
            {buildMutation.isPending ? "Building\u2026" : "Build image"}
          </Button>
          <Button onClick={() => pushMutation.mutate()} disabled={pushMutation.isPending} variant="outline">
            {pushMutation.isPending ? "Pushing\u2026" : (registry?.pushButtonLabel ?? "Push to registry")}
          </Button>
          <Button asChild variant="outline" size="sm">
            <Link href={`/pipeline/${projectId}`}>Pipeline</Link>
          </Button>
        </div>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="flex flex-wrap items-center gap-2">
            Image history
          </CardTitle>
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
                    <TableCell className="max-w-[140px] truncate font-mono text-xs">{row.digest ?? "\u2014"}</TableCell>
                  </TableRow>))}
              </TableBody>
            </Table>)}
          {!historyQuery.isLoading && (historyQuery.data?.length ?? 0) === 0 ? (<p className="py-6 text-center text-sm text-muted">No images recorded yet. Run a build or push.</p>) : null}
        </CardContent>
      </Card>

      {registryQuery.isLoading ? (<Skeleton className="h-12 w-full"/>) : registry ? (<p className="text-xs text-muted">
          {registry.configured && registry.verified
            ? `${registry.message} Image references use the configured registry.`
            : registry.configHint}
        </p>) : null}
    </div>);
}
