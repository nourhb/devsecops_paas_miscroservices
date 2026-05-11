"use client";
import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { Activity, ArrowLeft, Box, ChevronRight, Copy, ExternalLink, FolderGit2, GitBranch, History, Play, Rocket, RotateCcw, Shield, Wrench } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { GitHubPushBuildPrompt } from "@/components/build/github-push-build-prompt";
import { deploymentFailureStageLabel } from "@/components/deployments/deployment-logs-view";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { argocdApi, pipelineApi, projectApi, securityApi } from "@/lib/api";
import { queryHttpData, queryHttpDetails, queryHttpMessage } from "@/lib/query-http-message";
import type { DeploymentStatus } from "@/types";
import { cn } from "@/lib/utils";
function statusBadgeVariant(status: string | undefined, ok: string[]): "success" | "warning" | "danger" | "outline" {
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
    const params = useParams<{
        id: string;
    }>();
    const projectId = params.id;
    const router = useRouter();
    const queryClient = useQueryClient();
    const projectQuery = useQuery({
        queryKey: ["project", projectId],
        queryFn: () => projectApi.getProject(projectId),
        refetchInterval: 10000
    });
    const statusQuery = useQuery({
        queryKey: ["status", projectId],
        queryFn: () => pipelineApi.getStatus(projectId) as Promise<DeploymentStatus>,
        refetchInterval: 10000
    });
    const argoQuery = useQuery({
        queryKey: ["argocd", projectId],
        queryFn: () => argocdApi.getStatus(projectId),
        refetchInterval: 20000
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
        refetchInterval: 15000
    });
    const securityQuery = useQuery({
        queryKey: ["security", projectId],
        queryFn: () => securityApi.getSecurity(projectId),
        refetchInterval: 20000
    });
    const buildMutation = useMutation({
        mutationFn: () => pipelineApi.triggerBuild(projectId),
        onSuccess: (data) => {
            queryClient.invalidateQueries({ queryKey: ["status", projectId] });
            queryClient.invalidateQueries({ queryKey: ["project", projectId] });
            toast.success(data.message || "Build started");
        },
        onError: (err) => {
            const msg = queryHttpMessage(err, "Could not trigger build");
            const details = queryHttpDetails(err);
            const data = queryHttpData(err);
            const jobUrl = typeof data?.jobUrl === "string" ? data.jobUrl : null;
            toast.error(msg, {
                ...(details ? { description: details.replace(/\s+/g, " ").trim().slice(0, 280) } : {}),
                ...(jobUrl
                    ? {
                        action: {
                            label: "Open build run",
                            onClick: () => window.open(jobUrl, "_blank", "noopener,noreferrer")
                        }
                    }
                    : {})
            });
        }
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
            }
            else {
                toast.success(msg);
            }
        },
        onError: (err) => {
            const msg = queryHttpMessage(err, "Deploy failed \u2014 check the build backend and deploy parameters");
            const details = queryHttpDetails(err);
            const data = queryHttpData(err);
            const deploymentId = typeof data?.deploymentId === "string" ? data.deploymentId : null;
            const description = details
                ? details.replace(/\s+/g, " ").trim().slice(0, 280)
                : deploymentId
                    ? "Open deployment logs to inspect the full upstream response."
                    : undefined;
            toast.error(msg, {
                ...(description ? { description } : {}),
                ...(deploymentId
                    ? {
                        action: {
                            label: "Open logs",
                            onClick: () => router.push(`/deployments/${deploymentId}`)
                        }
                    }
                    : {})
            });
        }
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
        }
        catch {
            toast.error("Could not copy");
        }
    };
    if (projectQuery.isLoading) {
        return (<div className="space-y-6">
        <Skeleton className="h-4 w-48"/>
        <Skeleton className="h-12 w-2/3 max-w-md"/>
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
          <Skeleton className="h-32"/>
          <Skeleton className="h-32"/>
          <Skeleton className="h-32"/>
        </div>
        <Skeleton className="h-64 w-full"/>
      </div>);
    }
    if (projectQuery.isError || !projectQuery.data) {
        return (<Card className="border-danger/30">
        <CardHeader>
          <CardTitle>Project unavailable</CardTitle>
          <CardDescription>
            This project does not exist or your account does not have access (developers only see their own projects).
          </CardDescription>
        </CardHeader>
        <CardContent>
          <Button asChild variant="outline">
            <Link href="/projects">
              <ArrowLeft className="mr-2 h-4 w-4"/>
              Back to projects
            </Link>
          </Button>
        </CardContent>
      </Card>);
    }
    const project = projectQuery.data;
    const status = statusQuery.data;
    const refreshing = statusQuery.isFetching && !statusQuery.isLoading;
    const latestDeployment = deploymentsQuery.data?.[0] ?? null;
    const activeDeployment = deploymentsQuery.data?.find((row) => row.status === "PENDING" || row.status === "DEPLOYING") ?? null;
    const imageTag = status?.imageTag || latestDeployment?.artifactImage || project.imageTag || "";
    const securityData = securityQuery.data;
    const navTiles = [
        {
            href: `/pipeline/${projectId}`,
            title: "CI/CD pipeline",
            description: `Build: ${project.buildStatus} · Deploy: ${status?.lastDeploymentStatus ?? project.lastDeploymentStatus}`,
            icon: GitBranch,
            badge: status?.lastDeploymentStatus ?? project.lastDeploymentStatus,
            badgeVariant: statusBadgeVariant(status?.lastDeploymentStatus ?? project.lastDeploymentStatus, ["SUCCESS", "DEPLOYED"])
        },
        {
            href: `/docker/${projectId}`,
            title: "Docker & registry",
            description: imageTag || "No image built yet.",
            icon: Box,
            badge: imageTag ? "Image ready" : "No image",
            badgeVariant: imageTag ? "success" : "outline"
        },
        {
            href: `/security/${projectId}`,
            title: "Security",
            description: securityData?.securitySummary ?? "Security signals load from Trivy, SonarQube, Dependency-Track, Cosign, and policy gates.",
            icon: Shield,
            badge: securityData?.qualityGateStatus ?? "Loading",
            badgeVariant: securityData?.qualityGateStatus === "PASSED" ? "success" : securityData ? "danger" : "outline"
        },
        {
            href: `/monitoring/${projectId}`,
            title: "Monitoring",
            description: `${status?.namespace ?? project.namespace} · Pod: ${status?.podStatus ?? project.podStatus}`,
            icon: Activity,
            badge: status?.podStatus ?? project.podStatus,
            badgeVariant: statusBadgeVariant(status?.podStatus ?? project.podStatus, ["RUNNING", "HEALTHY"])
        }
    ] as const;
    return (<div className="space-y-8">
      
      <nav className="flex flex-wrap items-center gap-1 text-sm text-muted">
        <Link href="/projects" className="hover:text-foreground">
          Projects
        </Link>
        <ChevronRight className="h-4 w-4 shrink-0 opacity-60"/>
        <span className="truncate text-foreground">{project.projectName}</span>
      </nav>

      
      <header className="grid gap-6 border-b border-border pb-8 xl:grid-cols-[minmax(0,1fr)_auto] xl:items-start">
        <div className="min-w-0 space-y-3">
          <div className="flex items-center gap-2 text-primary">
            <FolderGit2 className="h-8 w-8 shrink-0" aria-hidden/>
            <span className="text-xs font-semibold uppercase tracking-wider">Project</span>
          </div>
          <h1 className="text-3xl font-semibold tracking-tight">{project.projectName}</h1>
          <a href={project.gitRepositoryUrl} target="_blank" rel="noopener noreferrer" className="flex max-w-full items-start gap-2 font-mono text-sm text-primary hover:underline">
            <span className="min-w-0 break-all">{project.gitRepositoryUrl}</span>
            <ExternalLink className="mt-0.5 h-3.5 w-3.5 shrink-0 opacity-80"/>
          </a>
          <div className="flex flex-wrap items-center gap-2">
            <Badge variant="outline">Branch: {project.branch}</Badge>
            <Badge variant="outline">NS: {project.namespace}</Badge>
            <Badge variant="outline">{project.language}</Badge>
            <Button type="button" variant="ghost" size="sm" className="h-7 gap-1 px-2 text-xs" onClick={copyId}>
              <Copy className="h-3 w-3"/>
              ID
            </Button>
          </div>
          <p className="text-xs text-muted">
            Created {new Date(project.createdAt).toLocaleString()}
            {refreshing ? (<span className="ml-2 inline-flex items-center gap-1">
                <span className="inline-block h-1.5 w-1.5 animate-pulse rounded-full bg-primary"/>
                Refreshing status…
              </span>) : null}
          </p>
        </div>

        <div className="flex flex-wrap items-start gap-2 xl:justify-end">
          <Badge className="h-9 max-w-full justify-center px-3 py-1.5" variant={statusBadgeVariant(status?.lastDeploymentStatus ?? project.lastDeploymentStatus, [
            "SUCCESS",
            "DEPLOYED"
        ])}>
            Deploy: {status?.lastDeploymentStatus ?? project.lastDeploymentStatus}
          </Badge>
          <Badge className="h-9 max-w-full justify-center px-3 py-1.5" variant={statusBadgeVariant(project.buildStatus, ["SUCCESS"])}>
            Build: {project.buildStatus}
          </Badge>
          <Badge className="h-9 max-w-full justify-center px-3 py-1.5" variant="outline">
            Pod: {status?.podStatus ?? project.podStatus}
          </Badge>
        </div>
      </header>

      <GitHubPushBuildPrompt projectId={projectId} pending={project.pendingGitHubPush} projectBranch={project.branch} gitCredentialsId={project.gitCredentialsId}/>

      
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-lg">
            <Play className="h-5 w-5 text-primary"/>
            Operations
          </CardTitle>
          <CardDescription>
            Build and deploy use the selected platform backend while keeping the same project workflow and live status view.
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-wrap items-center gap-3">
          {project.url ? (<>
              <Button asChild>
                <a href={project.url} target="_blank" rel="noopener noreferrer">
                  <ExternalLink className="mr-2 h-4 w-4"/>
                  Open app
                </a>
              </Button>
              {appReachQuery.data ? (<Badge variant={appReachQuery.data.reachable
                    ? "success"
                    : appReachQuery.data.error === "synthetic_local"
                        ? "outline"
                        : "warning"} className="h-9">
                  {appReachQuery.data.reachable
                    ? `Live · HTTP ${appReachQuery.data.statusCode ?? "OK"}`
                    : appReachQuery.data.error === "no_url"
                        ? "App URL not set"
                        : appReachQuery.data.error === "synthetic_local"
                            ? ".local URL \u2014 not probed from PaaS"
                            : "Not reachable (probe)"}
                </Badge>) : appReachQuery.isLoading ? (<Badge variant="outline" className="h-9">
                  Checking reachability…
                </Badge>) : null}
            </>) : null}
          <Button onClick={() => buildMutation.mutate()} disabled={buildMutation.isPending}>
            <Wrench className="mr-2 h-4 w-4"/>
            {buildMutation.isPending ? "Building\u2026" : "Trigger build"}
          </Button>
          <Button onClick={() => deployMutation.mutate()} disabled={deployMutation.isPending || Boolean(activeDeployment)}>
            <Rocket className="mr-2 h-4 w-4"/>
            {deployMutation.isPending ? "Deploying\u2026" : activeDeployment ? "Deploy running" : "Deploy"}
          </Button>
          {activeDeployment ? (<Button variant="outline" asChild>
            <Link href={`/deployments/${activeDeployment.id}`}>Open running deploy</Link>
          </Button>) : null}
          <Button variant="destructive" onClick={() => rollbackMutation.mutate()} disabled={rollbackMutation.isPending}>
            <RotateCcw className="mr-2 h-4 w-4"/>
            {rollbackMutation.isPending ? "Rolling back\u2026" : "Rollback"}
          </Button>
          <Button variant="outline" asChild>
            <Link href={`/projects/${projectId}/edit`}>Edit project</Link>
          </Button>
          <Button variant="outline" asChild>
            <Link href="/projects">
              <ArrowLeft className="mr-2 h-4 w-4"/>
              All projects
            </Link>
          </Button>
        </CardContent>
      </Card>

      
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-lg">
            <History className="h-5 w-5 text-primary"/>
            Deployments
          </CardTitle>
          <CardDescription className="flex flex-wrap items-center gap-x-2 gap-y-1">
            <span>Deploy history for this project (auto-refresh every 5s). <span className="font-medium text-foreground">View</span> opens live logs.</span>
            {deploymentsQuery.isFetching && !deploymentsQuery.isLoading ? (<span className="text-xs font-normal text-muted-foreground">Updating…</span>) : null}
          </CardDescription>
        </CardHeader>
        <CardContent>
          {deploymentsQuery.isLoading ? (<Skeleton className="h-40 w-full"/>) : deploymentsQuery.isError ? (<p className="text-sm text-danger">
              {queryHttpMessage(deploymentsQuery.error, "Could not load deployments.")}
            </p>) : !deploymentsQuery.data?.length ? (<p className="text-sm text-muted">No deployments yet. Use Deploy above to start a managed build run.</p>) : (<Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Status</TableHead>
                  <TableHead>Failure</TableHead>
                  <TableHead>Created</TableHead>
                  <TableHead>Run</TableHead>
                  <TableHead>Artifact</TableHead>
                  <TableHead>App URL</TableHead>
                  <TableHead className="text-right">Details</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {deploymentsQuery.data.map((row) => (<TableRow key={row.id}>
                    <TableCell>
                      <Badge variant={deploymentJobBadgeVariant(row.status)}>{row.status}</Badge>
                    </TableCell>
                    <TableCell className="max-w-[220px]">
                      {row.status === "FAILED" ? (<div className="space-y-0.5 text-xs">
                          {row.failureReason ? (<p className="font-medium text-danger">
                              {deploymentFailureStageLabel(row.failureReason)}
                            </p>) : null}
                          {row.failureMessage ? (<p className="line-clamp-2 text-muted" title={row.failureMessage}>
                              {row.failureMessage}
                            </p>) : !row.failureReason ? (<span className="text-muted">—</span>) : null}
                        </div>) : (<span className="text-muted">—</span>)}
                    </TableCell>
                    <TableCell className="text-muted">
                      {new Date(row.createdAt).toLocaleString()}
                    </TableCell>
                    <TableCell className="font-mono text-xs">
                      {row.buildRunId ?? row.buildNumber ?? "\u2014"}
                      {row.buildProvider ? <div className="text-muted-foreground">{row.buildProvider}</div> : null}
                    </TableCell>
                    <TableCell className="max-w-[220px] truncate font-mono text-xs">
                      {row.artifactImage ? row.artifactImage : "\u2014"}
                    </TableCell>
                    <TableCell className="max-w-[200px] truncate text-xs">
                      {row.url ? (<a href={row.url} target="_blank" rel="noopener noreferrer" className="text-primary hover:underline">
                          {row.url}
                        </a>) : ("\u2014")}
                    </TableCell>
                    <TableCell className="text-right">
                      <Button variant="outline" size="sm" asChild>
                        <Link href={`/deployments/${row.id}`}>View</Link>
                      </Button>
                    </TableCell>
                  </TableRow>))}
              </TableBody>
            </Table>)}
        </CardContent>
      </Card>

      
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Argo CD</CardTitle>
          <CardDescription>Application health and sync status when Argo API is configured.</CardDescription>
        </CardHeader>
        <CardContent>
          {argoQuery.isLoading ? (<Skeleton className="h-10 w-full max-w-md"/>) : (<div className="flex flex-wrap gap-2">
              <Badge variant="outline" className="font-mono text-xs">
                {argoQuery.data?.appName ?? "\u2014"}
              </Badge>
              <Badge variant={argoQuery.data?.health === "Healthy" ? "success" : "warning"}>
                {argoQuery.data?.health ?? "Unknown"}
              </Badge>
              <Badge variant="outline">Sync: {argoQuery.data?.syncStatus ?? "\u2014"}</Badge>
            </div>)}
        </CardContent>
      </Card>

      
      <section className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Repository</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            <div>
              <p className="text-xs font-medium uppercase tracking-wide text-muted">Repository URL</p>
              <a href={project.gitRepositoryUrl} target="_blank" rel="noopener noreferrer" className="mt-0.5 block break-all font-mono text-xs text-primary hover:underline">
                {project.gitRepositoryUrl}
              </a>
            </div>
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
            <div>
              <p className="text-xs font-medium uppercase tracking-wide text-muted">Build profile</p>
              <p className="mt-0.5">{project.buildProfile}</p>
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
              <p className="mt-0.5 break-all font-mono text-xs">{status?.imageTag || project.imageTag || "\u2014"}</p>
            </div>
            <div>
              <p className="text-xs font-medium uppercase tracking-wide text-muted">Pod status</p>
              <p className="mt-0.5">{status?.podStatus ?? project.podStatus}</p>
            </div>
            <div>
              <p className="text-xs font-medium uppercase tracking-wide text-muted">Build backend</p>
              <p className="mt-0.5">{project.buildProvider}</p>
            </div>
          </CardContent>
        </Card>

        <Card className="md:col-span-2 lg:col-span-1">
          <CardHeader>
            <CardTitle className="text-base">Scaffolding</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm text-muted">
            <p>
              Build mode: <span className="text-foreground">{project.buildMode}</span>
            </p>
            <p>
              Template: <span className="text-foreground">{project.buildTemplateName}</span>
            </p>
            <p>
              Detection: <span className="text-foreground">{project.buildDetectionReason}</span>
            </p>
          </CardContent>
        </Card>
      </section>

      
      <section>
        <h2 className="mb-4 text-lg font-semibold">Platform areas</h2>
        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          {navTiles.map((tile) => {
            const Icon = tile.icon;
            return (<Link key={tile.href} href={tile.href} className="group block h-full">
                <Card className={cn("h-full transition-colors", "hover:border-primary/40 hover:bg-muted/30")}>
                  <CardHeader className="pb-2">
                    <div className="flex items-center justify-between gap-2">
                      <Icon className="h-5 w-5 text-primary"/>
                      <Badge variant={tile.badgeVariant} className="max-w-[130px] truncate text-xs">
                        {tile.badge}
                      </Badge>
                    </div>
                    <CardTitle className="text-base">{tile.title}</CardTitle>
                  </CardHeader>
                  <CardContent className="space-y-3">
                    <CardDescription className="line-clamp-3 text-xs leading-relaxed">{tile.description}</CardDescription>
                    <div className="flex items-center gap-1 text-xs font-medium text-primary">
                      Open
                      <ChevronRight className="h-3.5 w-3.5 transition-transform group-hover:translate-x-0.5"/>
                    </div>
                  </CardContent>
                </Card>
              </Link>);
        })}
        </div>
      </section>

      
      <section className="grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Build logs</CardTitle>
            <CardDescription>{project.buildProvider} build stage output</CardDescription>
          </CardHeader>
          <CardContent>
            <pre className={cn("max-h-72 overflow-auto rounded-lg border border-border p-4 text-xs leading-relaxed", "bg-background/80 font-mono text-foreground/90")}>
              {status?.buildLogs?.trim() || "No build log text is stored yet.\n\nOpen Operations \u2192 Trigger Build. Logs appear once Jenkins runs and reconciles; use Cluster \u2192 Logs to browse recent deployment records across the workspace."}
            </pre>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-base">Deployment logs</CardTitle>
            <CardDescription>GitOps, registry, policy gates, and Argo CD</CardDescription>
          </CardHeader>
          <CardContent>
            <pre className={cn("max-h-72 overflow-auto rounded-lg border border-border p-4 text-xs leading-relaxed", "bg-background/80 font-mono text-foreground/90")}>
              {status?.deploymentLogs?.trim() ||
            "No deployment log text yet.\n\nRun a full deploy from Operations after a good build. Stored output includes registry/GitOps/policy stages when available."}
            </pre>
          </CardContent>
        </Card>
      </section>
    </div>);
}
