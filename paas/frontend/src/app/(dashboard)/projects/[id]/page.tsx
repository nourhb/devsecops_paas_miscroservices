"use client";

import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import {
  Activity,
  ArrowLeft,
  Box,
  ChevronRight,
  Copy,
  ExternalLink,
  FolderGit2,
  GitBranch,
  History,
  Play,
  Rocket,
  RotateCcw,
  Shield,
  Wrench
} from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { deploymentFailureStageLabel } from "@/components/deployments/deployment-logs-view";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { argocdApi, pipelineApi, projectApi } from "@/lib/api";
import type { DeploymentStatus } from "@/types";
import { cn } from "@/lib/utils";

function statusBadgeVariant(
  status: string | undefined,
  ok: string[]
): "success" | "warning" | "danger" | "outline" {
  const s = (status || "").toUpperCase();
  if (ok.some((x) => s === x.toUpperCase())) {
    return "success";
  }
  if (s.includes("FAIL") || s.includes("ERROR")) {
    return "danger";
  }
  if (s === "NOT_STARTED" || s === "NOT_DEPLOYED" || s === "UNKNOWN" || !s) {
    return "outline";
  }
  return "warning";
}

function deploymentJobBadgeVariant(status: string): "success" | "danger" | "warning" {
  const s = status.toUpperCase();
  if (s === "SUCCESS" || s === "DEPLOYED") {
    return "success";
  }
  if (s === "FAILED") {
    return "danger";
  }
  if (s === "DEPLOYING" || s === "PENDING") {
    return "warning";
  }
  return "warning";
}

export default function ProjectDetailsPage() {
  const params = useParams<{ id: string }>();
  const projectId = params.id;
  const router = useRouter();
  const queryClient = useQueryClient();

  const projectQuery = useQuery({
    queryKey: ["project", projectId],
    queryFn: () => projectApi.getProject(projectId),
    refetchInterval: 10_000
  });

  const statusQuery = useQuery({
    queryKey: ["status", projectId],
    queryFn: () => pipelineApi.getStatus(projectId) as Promise<DeploymentStatus>,
    refetchInterval: 10_000
  });

  const argoQuery = useQuery({
    queryKey: ["argocd", projectId],
    queryFn: () => argocdApi.getStatus(projectId),
    refetchInterval: 20_000
  });

  const deploymentsQuery = useQuery({
    queryKey: ["deployments", projectId],
    queryFn: () => projectApi.listDeployments(projectId),
    refetchInterval: 5000
  });

  const appReachQuery = useQuery({
    queryKey: ["app-reachability", projectId],
    queryFn: () => projectApi.getAppReachability(projectId),
    enabled: Boolean(projectQuery.data?.url),
    refetchInterval: 15_000
  });

  const buildMutation = useMutation({
    mutationFn: () => pipelineApi.triggerBuild(projectId),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: ["status", projectId] });
      queryClient.invalidateQueries({ queryKey: ["project", projectId] });
      toast.success(data.message || "Build started");
    },
    onError: () => toast.error("Could not trigger build")
  });

  const deployMutation = useMutation({
    mutationFn: () => pipelineApi.deploy(projectId),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: ["status", projectId] });
      queryClient.invalidateQueries({ queryKey: ["argocd", projectId] });
      queryClient.invalidateQueries({ queryKey: ["deployments", projectId] });
      queryClient.invalidateQueries({ queryKey: ["project", projectId] });
      queryClient.invalidateQueries({ queryKey: ["app-reachability", projectId] });
      const msg = data.message || "Deployment queued";
      if (data.deploymentId) {
        toast.success(msg, {
          action: {
            label: "Open",
            onClick: () => router.push(`/deployments/${data.deploymentId}`)
          }
        });
      } else {
        toast.success(msg);
      }
    },
    onError: () => toast.error("Deploy failed — check Jenkins and parameters")
  });

  const rollbackMutation = useMutation({
    mutationFn: () => pipelineApi.rollback(projectId),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: ["status", projectId] });
      toast.success(data.message || "Rollback complete");
    },
    onError: () => toast.error("Rollback failed")
  });

  const copyId = async () => {
    try {
      await navigator.clipboard.writeText(projectId);
      toast.success("Project ID copied");
    } catch {
      toast.error("Could not copy");
    }
  };

  if (projectQuery.isLoading) {
    return (
      <div className="space-y-6">
        <Skeleton className="h-4 w-48" />
        <Skeleton className="h-12 w-2/3 max-w-md" />
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
          <Skeleton className="h-32" />
          <Skeleton className="h-32" />
          <Skeleton className="h-32" />
        </div>
        <Skeleton className="h-64 w-full" />
      </div>
    );
  }

  if (projectQuery.isError || !projectQuery.data) {
    return (
      <Card className="border-danger/30">
        <CardHeader>
          <CardTitle>Project unavailable</CardTitle>
          <CardDescription>
            This project does not exist or your account does not have access (developers only see their own projects).
          </CardDescription>
        </CardHeader>
        <CardContent>
          <Button asChild variant="outline">
            <Link href="/projects">
              <ArrowLeft className="mr-2 h-4 w-4" />
              Back to projects
            </Link>
          </Button>
        </CardContent>
      </Card>
    );
  }

  const project = projectQuery.data;
  const status = statusQuery.data;
  const refreshing = statusQuery.isFetching && !statusQuery.isLoading;

  const navTiles = [
    {
      href: `/pipeline/${projectId}`,
      title: "CI/CD pipeline",
      description: "Jenkins builds, deploy, rollback, and live console output.",
      icon: GitBranch
    },
    {
      href: `/docker/${projectId}`,
      title: "Docker & registry",
      description: "Build images, push to Docker Hub, and browse image history.",
      icon: Box
    },
    {
      href: `/security/${projectId}`,
      title: "Security",
      description: "Trivy, SonarQube, Dependency-Track, Cosign, and OPA signals.",
      icon: Shield
    },
    {
      href: `/monitoring/${projectId}`,
      title: "Monitoring",
      description: "Prometheus-style metrics and embedded Grafana dashboards.",
      icon: Activity
    }
  ] as const;

  return (
    <div className="space-y-8">
      {/* Breadcrumb */}
      <nav className="flex flex-wrap items-center gap-1 text-sm text-muted">
        <Link href="/projects" className="hover:text-foreground">
          Projects
        </Link>
        <ChevronRight className="h-4 w-4 shrink-0 opacity-60" />
        <span className="truncate text-foreground">{project.projectName}</span>
      </nav>

      {/* Hero */}
      <header className="flex flex-col gap-6 border-b border-border pb-8 lg:flex-row lg:items-start lg:justify-between">
        <div className="min-w-0 space-y-3">
          <div className="flex items-center gap-2 text-primary">
            <FolderGit2 className="h-8 w-8 shrink-0" aria-hidden />
            <span className="text-xs font-semibold uppercase tracking-wider">Project</span>
          </div>
          <h1 className="text-3xl font-semibold tracking-tight">{project.projectName}</h1>
          <a
            href={project.gitRepositoryUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex max-w-full items-center gap-2 break-all font-mono text-sm text-primary hover:underline"
          >
            {project.gitRepositoryUrl}
            <ExternalLink className="h-3.5 w-3.5 shrink-0 opacity-80" />
          </a>
          <div className="flex flex-wrap items-center gap-2">
            <Badge variant="outline">Branch: {project.branch}</Badge>
            <Badge variant="outline">NS: {project.namespace}</Badge>
            <Badge variant="outline">{project.language}</Badge>
            <Button type="button" variant="ghost" size="sm" className="h-7 gap-1 px-2 text-xs" onClick={copyId}>
              <Copy className="h-3 w-3" />
              ID
            </Button>
          </div>
          <p className="text-xs text-muted">
            Created {new Date(project.createdAt).toLocaleString()}
            {refreshing ? (
              <span className="ml-2 inline-flex items-center gap-1">
                <span className="inline-block h-1.5 w-1.5 animate-pulse rounded-full bg-primary" />
                Refreshing status…
              </span>
            ) : null}
          </p>
        </div>

        <div className="flex shrink-0 flex-col gap-2 sm:flex-row sm:items-start">
          <Badge
            className="h-9 justify-center px-3 py-1.5"
            variant={statusBadgeVariant(status?.lastDeploymentStatus ?? project.lastDeploymentStatus, [
              "SUCCESS",
              "DEPLOYED"
            ])}
          >
            Deploy: {status?.lastDeploymentStatus ?? project.lastDeploymentStatus}
          </Badge>
          <Badge
            className="h-9 justify-center px-3 py-1.5"
            variant={statusBadgeVariant(project.buildStatus, ["SUCCESS"])}
          >
            Build: {project.buildStatus}
          </Badge>
          <Badge className="h-9 justify-center px-3 py-1.5" variant="outline">
            Pod: {status?.podStatus ?? project.podStatus}
          </Badge>
        </div>
      </header>

      {/* Actions */}
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-lg">
            <Play className="h-5 w-5 text-primary" />
            Operations
          </CardTitle>
          <CardDescription>
            Build runs Jenkins only. Deploy triggers a parameterized Jenkins job and records status in Deployments
            (polled until SUCCESS or FAILED).
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-wrap items-center gap-3">
          {project.url ? (
            <>
              <Button asChild>
                <a href={project.url} target="_blank" rel="noopener noreferrer">
                  <ExternalLink className="mr-2 h-4 w-4" />
                  Open app
                </a>
              </Button>
              {appReachQuery.data ? (
                <Badge variant={appReachQuery.data.reachable ? "success" : "warning"} className="h-9">
                  {appReachQuery.data.reachable
                    ? `Live · HTTP ${appReachQuery.data.statusCode ?? "OK"}`
                    : appReachQuery.data.error === "no_url"
                      ? "App URL not set"
                      : "Not reachable (probe)"}
                </Badge>
              ) : appReachQuery.isLoading ? (
                <Badge variant="outline" className="h-9">
                  Checking reachability…
                </Badge>
              ) : null}
            </>
          ) : null}
          <Button onClick={() => buildMutation.mutate()} disabled={buildMutation.isPending}>
            <Wrench className="mr-2 h-4 w-4" />
            {buildMutation.isPending ? "Building…" : "Trigger build"}
          </Button>
          <Button onClick={() => deployMutation.mutate()} disabled={deployMutation.isPending}>
            <Rocket className="mr-2 h-4 w-4" />
            {deployMutation.isPending ? "Deploying…" : "Deploy"}
          </Button>
          <Button variant="destructive" onClick={() => rollbackMutation.mutate()} disabled={rollbackMutation.isPending}>
            <RotateCcw className="mr-2 h-4 w-4" />
            {rollbackMutation.isPending ? "Rolling back…" : "Rollback"}
          </Button>
          <Button variant="outline" asChild>
            <Link href={`/projects/${projectId}/edit`}>Edit project</Link>
          </Button>
          <Button variant="outline" asChild>
            <Link href="/projects">
              <ArrowLeft className="mr-2 h-4 w-4" />
              All projects
            </Link>
          </Button>
        </CardContent>
      </Card>

      {/* Deployments */}
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-lg">
            <History className="h-5 w-5 text-primary" />
            Deployments
          </CardTitle>
          <CardDescription>
            Recent deploy attempts for this project. List refreshes every 5 seconds. Open a row for live logs.
          </CardDescription>
        </CardHeader>
        <CardContent>
          {deploymentsQuery.isLoading ? (
            <Skeleton className="h-40 w-full" />
          ) : deploymentsQuery.isError ? (
            <p className="text-sm text-danger">Could not load deployments.</p>
          ) : !deploymentsQuery.data?.length ? (
            <p className="text-sm text-muted">No deployments yet. Use Deploy above to start a Jenkins run.</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Status</TableHead>
                  <TableHead>Failure</TableHead>
                  <TableHead>Created</TableHead>
                  <TableHead>Build #</TableHead>
                  <TableHead>App URL</TableHead>
                  <TableHead className="text-right">Details</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {deploymentsQuery.data.map((row) => (
                  <TableRow key={row.id}>
                    <TableCell>
                      <Badge variant={deploymentJobBadgeVariant(row.status)}>{row.status}</Badge>
                    </TableCell>
                    <TableCell className="max-w-[220px]">
                      {row.status === "FAILED" ? (
                        <div className="space-y-0.5 text-xs">
                          {row.failureReason ? (
                            <p className="font-medium text-danger">
                              {deploymentFailureStageLabel(row.failureReason)}
                            </p>
                          ) : null}
                          {row.failureMessage ? (
                            <p className="line-clamp-2 text-muted" title={row.failureMessage}>
                              {row.failureMessage}
                            </p>
                          ) : !row.failureReason ? (
                            <span className="text-muted">—</span>
                          ) : null}
                        </div>
                      ) : (
                        <span className="text-muted">—</span>
                      )}
                    </TableCell>
                    <TableCell className="text-muted">
                      {new Date(row.createdAt).toLocaleString()}
                    </TableCell>
                    <TableCell className="font-mono text-xs">
                      {row.buildNumber ?? "—"}
                    </TableCell>
                    <TableCell className="max-w-[200px] truncate text-xs">
                      {row.url ? (
                        <a
                          href={row.url}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="text-primary hover:underline"
                        >
                          {row.url}
                        </a>
                      ) : (
                        "—"
                      )}
                    </TableCell>
                    <TableCell className="text-right">
                      <Button variant="outline" size="sm" asChild>
                        <Link href={`/deployments/${row.id}`}>View</Link>
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      {/* Argo snapshot */}
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Argo CD</CardTitle>
          <CardDescription>Application health and sync status when Argo API is configured.</CardDescription>
        </CardHeader>
        <CardContent>
          {argoQuery.isLoading ? (
            <Skeleton className="h-10 w-full max-w-md" />
          ) : (
            <div className="flex flex-wrap gap-2">
              <Badge variant="outline" className="font-mono text-xs">
                {argoQuery.data?.appName ?? "—"}
              </Badge>
              <Badge variant={argoQuery.data?.health === "Healthy" ? "success" : "warning"}>
                {argoQuery.data?.health ?? "Unknown"}
              </Badge>
              <Badge variant="outline">Sync: {argoQuery.data?.syncStatus ?? "—"}</Badge>
            </div>
          )}
        </CardContent>
      </Card>

      {/* Detail grid */}
      <section className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Repository</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            <div>
              <p className="text-xs font-medium uppercase tracking-wide text-muted">Default branch</p>
              <p className="mt-0.5 font-mono">{project.branch}</p>
            </div>
            <div>
              <p className="text-xs font-medium uppercase tracking-wide text-muted">Kubernetes namespace</p>
              <p className="mt-0.5 font-mono">{project.namespace}</p>
            </div>
            <div>
              <p className="text-xs font-medium uppercase tracking-wide text-muted">Stack</p>
              <p className="mt-0.5">{project.language}</p>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-base">Runtime</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            <div>
              <p className="text-xs font-medium uppercase tracking-wide text-muted">Image tag</p>
              <p className="mt-0.5 break-all font-mono text-xs">{status?.imageTag || project.imageTag || "—"}</p>
            </div>
            <div>
              <p className="text-xs font-medium uppercase tracking-wide text-muted">Pod status</p>
              <p className="mt-0.5">{status?.podStatus ?? project.podStatus}</p>
            </div>
          </CardContent>
        </Card>

        <Card className="md:col-span-2 lg:col-span-1">
          <CardHeader>
            <CardTitle className="text-base">Scaffolding</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm text-muted">
            <p>
              Dockerfile generation:{" "}
              <span className="text-foreground">{project.autoGenerateDockerfile ? "Enabled" : "Disabled"}</span>
            </p>
            <p>
              Helm chart generation:{" "}
              <span className="text-foreground">{project.autoGenerateHelmChart ? "Enabled" : "Disabled"}</span>
            </p>
          </CardContent>
        </Card>
      </section>

      {/* Platform areas */}
      <section>
        <h2 className="mb-4 text-lg font-semibold">Platform areas</h2>
        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          {navTiles.map((tile) => {
            const Icon = tile.icon;
            return (
              <Link key={tile.href} href={tile.href} className="group block h-full">
                <Card
                  className={cn(
                    "h-full transition-colors",
                    "hover:border-primary/40 hover:bg-muted/30"
                  )}
                >
                  <CardHeader className="pb-2">
                    <div className="flex items-center justify-between gap-2">
                      <Icon className="h-5 w-5 text-primary" />
                      <ChevronRight className="h-4 w-4 text-muted opacity-0 transition-opacity group-hover:opacity-100" />
                    </div>
                    <CardTitle className="text-base">{tile.title}</CardTitle>
                  </CardHeader>
                  <CardContent>
                    <CardDescription className="text-xs leading-relaxed">{tile.description}</CardDescription>
                  </CardContent>
                </Card>
              </Link>
            );
          })}
        </div>
      </section>

      {/* Logs */}
      <section className="grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Build logs</CardTitle>
            <CardDescription>Jenkins / build stage output</CardDescription>
          </CardHeader>
          <CardContent>
            <pre
              className={cn(
                "max-h-72 overflow-auto rounded-lg border border-border p-4 text-xs leading-relaxed",
                "bg-background/80 font-mono text-foreground/90"
              )}
            >
              {status?.buildLogs?.trim() || "No build logs yet. Trigger a build from Operations."}
            </pre>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-base">Deployment logs</CardTitle>
            <CardDescription>GitOps, registry, policy gates, and Argo CD</CardDescription>
          </CardHeader>
          <CardContent>
            <pre
              className={cn(
                "max-h-72 overflow-auto rounded-lg border border-border p-4 text-xs leading-relaxed",
                "bg-background/80 font-mono text-foreground/90"
              )}
            >
              {status?.deploymentLogs?.trim() ||
                "No deployment logs yet. Run a full deploy after a successful build path."}
            </pre>
          </CardContent>
        </Card>
      </section>
    </div>
  );
}
