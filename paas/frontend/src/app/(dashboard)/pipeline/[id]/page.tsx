"use client";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { Activity, ArrowLeft, Box, CheckCircle2, ChevronRight, Circle, ExternalLink, GitBranch, Loader2, Rocket, RotateCcw, Server, Shield, Workflow, Wrench } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { GitHubPushBuildPrompt } from "@/components/build/github-push-build-prompt";
import { formatStageDurationMs, jenkinsStageRowUi } from "@/components/jenkins/jenkins-pipeline-stage-ui";
import { argocdApi, jenkinsUi, pipelineApi, projectApi, securityApi, type JenkinsPipelineStageRow, type JenkinsPipelineStagesResponse } from "@/lib/api";
import { queryHttpData, queryHttpDetails, queryHttpMessage } from "@/lib/query-http-message";
import type { DeploymentStatus, Project } from "@/types";
import { computeDeliveryPathStates } from "@/lib/delivery-path-state";
import { cn } from "@/lib/utils";
const STAGES = [
    { key: "build", label: "Build", description: "Jenkins compile & image" },
    { key: "gates", label: "Gates", description: "Sonar, Trivy, Cosign, OPA" },
    { key: "registry", label: "Registry", description: "Harbor / push" },
    { key: "gitops", label: "GitOps", description: "Helm values commit" },
    { key: "argo", label: "Argo CD", description: "Cluster sync" }
] as const;
/** Stage names match `paas/jenkins/Jenkinsfile.paas-deploy` (inline sync job). Keep in sync when stages are added. */
const PAAS_DEPLOY_INCREMENTAL_JENKINS_STAGES = [
    "Step 1 — Params validation",
    "Step 2 — Checkout du code (Git / GitHub)",
    "Step 3 — Construction de l'application",
    "Step 4 — Tests SCA (Dependency-Check, CycloneDX, Dependency-Track)",
    "Step 5 — Tests SAST (SonarQube)",
    "Step 6 — Création de l'image Docker",
    "Step 7 — Packaging du chart Helm",
    "Step 8 — Publication des artefacts (Artifactory)",
    "Step 9 — Signature de l'image (Cosign)",
    "Step 10 — DAST (OWASP ZAP baseline)",
    "Step 11 — Publication charts Helm (OCI → Harbor)",
    "Step 12 — GitOps (Argo CD) & archivage Jenkins"
] as const;
function displayBuildStatus(projectStatus: string | undefined, lastDeploymentStatus: string | undefined): string {
    const bs = (projectStatus || "").toUpperCase();
    const ds = (lastDeploymentStatus || "").toUpperCase();
    if (ds === "FAILED" && (bs === "BUILDING" || bs === "QUEUED")) {
        return "FAILED";
    }
    return projectStatus || "\u2014";
}
function buildHeaderBadgeVariant(buildLabel: string): "success" | "warning" | "danger" | "outline" {
    const u = (buildLabel || "").toUpperCase();
    if (u === "FAILED" || u === "FAILURE" || u === "ABORTED" || u === "UNSTABLE") {
        return "danger";
    }
    if (u === "SUCCESS" || u === "READY") {
        return "success";
    }
    if (u === "BUILDING" || u === "QUEUED" || u === "PUSHING") {
        return "warning";
    }
    return "outline";
}
function ArgoHealthBadge({ health }: {
    health: string | undefined;
}) {
    const h = (health || "").toLowerCase();
    if (h === "healthy" || h === "progressing") {
        return <Badge variant="success">Health: {health ?? "\u2014"}</Badge>;
    }
    if (h === "degraded" || h === "missing" || h === "unknown" || h === "suspended") {
        return <Badge variant="warning">Health: {health ?? "\u2014"}</Badge>;
    }
    if (h.includes("fail") || h === "unhealthy") {
        return <Badge variant="danger">Health: {health ?? "\u2014"}</Badge>;
    }
    return <Badge variant="outline">Health: {health ?? "\u2014"}</Badge>;
}
export default function PipelinePage() {
    const params = useParams<{
        id: string;
    }>();
    const projectId = params.id;
    const queryClient = useQueryClient();
    const projectQuery = useQuery({
        queryKey: ["project", projectId],
        queryFn: () => projectApi.getProject(projectId)
    });
    const statusQuery = useQuery({
        queryKey: ["status", projectId],
        queryFn: () => pipelineApi.getStatus(projectId) as Promise<DeploymentStatus>,
        refetchInterval: 8000
    });
    const argoQuery = useQuery({
        queryKey: ["argocd", projectId],
        queryFn: () => argocdApi.getStatus(projectId),
        refetchInterval: 12000
    });
    const securityQuery = useQuery({
        queryKey: ["dependency-track", projectId],
        queryFn: () => securityApi.getDependencyTrack(projectId),
        refetchInterval: 12000
    });
    const pipelineStagesQuery = useQuery({
        queryKey: ["jenkins-pipeline-stages", projectId],
        queryFn: ({ signal }) => jenkinsUi.pipelineStages(projectId, undefined, signal),
        enabled: Boolean(projectQuery.data),
        refetchInterval: () => {
            const proj = queryClient.getQueryData<Project>(["project", projectId]);
            const u = (s: string | undefined) => (s || "").toUpperCase();
            const appBusy = ["BUILDING", "QUEUED", "PUSHING"].includes(u(proj?.buildStatus));
            const stagesData = queryClient.getQueryData<JenkinsPipelineStagesResponse>(["jenkins-pipeline-stages", projectId]);
            const jenkinsBusy = Boolean(stagesData?.building);
            return appBusy || jenkinsBusy ? 3000 : 20000;
        }
    });
    const buildMutation = useMutation({
        mutationFn: () => pipelineApi.triggerBuild(projectId),
        onSuccess: (data) => {
            queryClient.invalidateQueries({ queryKey: ["status", projectId] });
            queryClient.invalidateQueries({ queryKey: ["project", projectId] });
            queryClient.invalidateQueries({ queryKey: ["jenkins-pipeline-stages", projectId] });
            toast.success(data.message || "Build triggered");
        },
        onError: (e: unknown) => {
            const msg = queryHttpMessage(e, "Build failed to start");
            const details = queryHttpDetails(e);
            const data = queryHttpData(e);
            const jobUrl = typeof data?.jobUrl === "string" ? data.jobUrl : null;
            toast.error(msg, {
                ...(details ? { description: details.replace(/\s+/g, " ").trim().slice(0, 280) } : {}),
                ...(jobUrl
                    ? {
                        action: {
                            label: "Open Jenkins",
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
            queryClient.invalidateQueries({ queryKey: ["project", projectId] });
            toast.success(data.message || "Deployment finished");
        },
        onError: (e: unknown) => {
            const msg = e && typeof e === "object" && "response" in e
                ? String((e as {
                    response?: {
                        data?: {
                            message?: string;
                        };
                    };
                }).response?.data?.message)
                : e instanceof Error
                    ? e.message
                    : "Deployment blocked or failed";
            toast.error(msg || "Deployment blocked or failed");
        }
    });
    const rollbackMutation = useMutation({
        mutationFn: () => pipelineApi.rollback(projectId),
        onSuccess: (data) => {
            queryClient.invalidateQueries({ queryKey: ["status", projectId] });
            queryClient.invalidateQueries({ queryKey: ["argocd", projectId] });
            toast.success(data.message || "Rollback completed");
        },
        onError: () => toast.error("Rollback failed")
    });
    if (projectQuery.isLoading) {
        return (<div className="space-y-6">
        <Skeleton className="h-4 w-56"/>
        <Skeleton className="h-10 w-2/3 max-w-lg"/>
        <Skeleton className="h-24 w-full"/>
        <div className="grid gap-4 lg:grid-cols-2">
          <Skeleton className="h-72"/>
          <Skeleton className="h-72"/>
        </div>
      </div>);
    }
    if (projectQuery.isError || !projectQuery.data) {
        return (<Card className="border-danger/30">
        <CardHeader>
          <CardTitle>Pipeline unavailable</CardTitle>
          <CardDescription>We could not load this project. Check the ID and your permissions.</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-wrap gap-2">
          <Button asChild variant="outline">
            <Link href="/projects">
              <ArrowLeft className="mr-2 h-4 w-4"/>
              Projects
            </Link>
          </Button>
        </CardContent>
      </Card>);
    }
    const project = projectQuery.data;
    const status = statusQuery.data;
    const refreshing = statusQuery.isFetching && !statusQuery.isLoading;
    const lastDs = status?.lastDeploymentStatus ?? project.lastDeploymentStatus;
    const displayBuild = displayBuildStatus(project.buildStatus, lastDs);
    const buildOk = ["SUCCESS", "READY"].includes((displayBuild || "").toUpperCase());
    const deployU = (lastDs || "").toUpperCase();
    const deployOk = deployU === "DEPLOYED" || deployU === "SUCCESS";
    const deployFailed = deployU === "FAILED";
    const securityMetrics = securityQuery.data?.metrics;
    const deliveryStates = computeDeliveryPathStates({
        buildStatus: project.buildStatus,
        lastDeploymentStatus: lastDs,
        buildLogs: status?.buildLogs,
        deploymentLogs: status?.deploymentLogs,
        argoHealth: argoQuery.data?.health,
        argoSyncStatus: argoQuery.data?.syncStatus
    });
    const wfStages = pipelineStagesQuery.data;
    const liveStagesList = wfStages?.stages ?? [];
    const jStarted = liveStagesList.filter((s) => s.status.toUpperCase() !== "NOT_EXECUTED").length;
    const jTotal = liveStagesList.length;
    const jProgressPct = jTotal > 0 ? Math.min(100, Math.round(jStarted / jTotal * 100)) : 0;
    return (<div className="space-y-8">
      <nav className="flex flex-wrap items-center gap-1 text-sm text-muted">
        <Link href="/projects" className="hover:text-foreground">
          Projects
        </Link>
        <ChevronRight className="h-4 w-4 shrink-0 opacity-60"/>
        <Link href={`/projects/${projectId}`} className="max-w-[200px] truncate hover:text-foreground">
          {project.projectName}
        </Link>
        <ChevronRight className="h-4 w-4 shrink-0 opacity-60"/>
        <span className="text-foreground">Pipeline</span>
      </nav>

      <header className="flex flex-col gap-6 border-b border-border pb-8 lg:flex-row lg:items-start lg:justify-between">
        <div className="min-w-0 space-y-2">
          <div className="flex items-center gap-2 text-primary">
            <Workflow className="h-8 w-8 shrink-0"/>
            <span className="text-xs font-semibold uppercase tracking-wider">CI/CD</span>
          </div>
          <h1 className="text-3xl font-semibold tracking-tight">Pipeline</h1>
          <p className="text-sm text-muted">
            <span className="font-medium text-foreground">{project.projectName}</span>
            <span className="mx-2 text-border">·</span>
            <span className="font-mono text-xs">{project.branch}</span>
            <span className="mx-2 text-border">·</span>
            <span className="font-mono text-xs">{project.namespace}</span>
          </p>
          <p className="break-all font-mono text-xs text-muted">{project.gitRepositoryUrl}</p>
          {refreshing ? (<p className="flex items-center gap-2 text-xs text-muted">
              <Loader2 className="h-3.5 w-3.5 animate-spin"/>
              Refreshing status…
            </p>) : null}
        </div>

        <div className="flex shrink-0 flex-wrap gap-2">
          <Badge variant={buildHeaderBadgeVariant(displayBuild)}>Build: {displayBuild}</Badge>
          <Badge variant={deployOk ? "success" : deployFailed ? "danger" : "outline"}>
            Deploy: {lastDs}
          </Badge>
          <Badge variant="outline">Pod: {status?.podStatus ?? project.podStatus}</Badge>
        </div>
      </header>

      <GitHubPushBuildPrompt projectId={projectId} pending={project.pendingGitHubPush} projectBranch={project.branch} gitCredentialsId={project.gitCredentialsId}/>

      
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Delivery path</CardTitle>
          <CardDescription>
            High-level phases below. The Jenkins inline job (<span className="font-mono text-xs">Jenkinsfile.paas-deploy</span>) runs{" "}
            <strong className="font-medium text-foreground">{PAAS_DEPLOY_INCREMENTAL_JENKINS_STAGES.length}</strong> numbered stages; search the build
            console for <span className="font-mono text-xs">Step N —</span> (e.g. Steps 4–5 SCA/SAST; Steps 10–12 ZAP, Helm OCI, archive / GitOps notes).
          </CardDescription>
        </CardHeader>
        <CardContent>
          <ul className="grid gap-6 sm:grid-cols-2 lg:grid-cols-5">
            {STAGES.map((stage) => {
            const state = deliveryStates[stage.key];
            return (<li key={stage.key} className="flex flex-col items-center text-center">
                  <div className={cn("mb-3 flex h-12 w-12 items-center justify-center rounded-full border-2 transition-colors", state === "done" && "border-success bg-success/15 text-success", state === "active" && "border-primary bg-primary/10 text-primary", state === "error" && "border-danger bg-danger/15 text-danger", state === "pending" && "border-border bg-muted/30 text-muted")}>
                    {state === "done" ? (<CheckCircle2 className="h-6 w-6"/>) : state === "error" ? (<Circle className="h-6 w-6"/>) : state === "active" ? (<Loader2 className="h-6 w-6 animate-spin"/>) : (<Circle className="h-5 w-5"/>)}
                  </div>
                  <p className="text-sm font-medium">{stage.label}</p>
                  <p className="mt-1 text-xs text-muted">{stage.description}</p>
                </li>);
        })}
          </ul>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div className="min-w-0 space-y-1">
              <CardTitle className="text-base">Jenkins pipeline (live)</CardTitle>
              <CardDescription>
                Stages mirror the Jenkins stage graph via <span className="font-mono text-xs">wfapi/describe</span> (install{" "}
                <strong className="font-medium text-foreground">Pipeline Stage View</strong> if you see a setup error). Polling speeds up while a build is
                running.
              </CardDescription>
            </div>
            {wfStages?.buildUrl ? (<Button asChild variant="outline" size="sm" className="shrink-0 gap-1.5">
                <a href={wfStages.buildUrl} target="_blank" rel="noopener noreferrer">
                  <ExternalLink className="h-3.5 w-3.5"/>
                  Open in Jenkins
                </a>
              </Button>) : null}
          </div>
          {wfStages ? (<div className="mt-3 flex flex-wrap items-center gap-2 text-xs text-muted">
              <code className="rounded border border-border bg-muted/40 px-2 py-1 font-mono text-[11px] text-foreground/90">
                {wfStages.displayJobName || wfStages.jobUrlPath || "—"}
              </code>
              {typeof wfStages.buildNumber === "number" ? <Badge variant="outline">#{wfStages.buildNumber}</Badge> : null}
              {wfStages.building ? <Badge variant="warning">Running on Jenkins</Badge> : null}
              {wfStages.runStatus ? <Badge variant="outline">Workflow: {wfStages.runStatus}</Badge> : null}
              {wfStages.result ? <Badge variant={buildHeaderBadgeVariant(wfStages.result)}>Result: {wfStages.result}</Badge> : null}
              {pipelineStagesQuery.isFetching ? <span className="inline-flex items-center gap-1 text-muted">
                  <Loader2 className="h-3 w-3 animate-spin"/>
                  Updating…
                </span> : null}
            </div>) : null}
        </CardHeader>
        <CardContent className="space-y-4">
          {pipelineStagesQuery.isLoading ? <Skeleton className="h-40 w-full"/> : null}
          {pipelineStagesQuery.isError ? (<p className="rounded-md border border-danger/35 bg-danger/10 px-3 py-2 text-sm text-danger">
              Could not load live stages from the API. Check your session and try again.
            </p>) : null}
          {wfStages?.skipped ? (<p className="rounded-md border border-border bg-muted/25 px-3 py-2 text-sm text-muted">{wfStages.reason || "Live Jenkins stages are not available for this project."}</p>) : null}
          {wfStages?.error ? (<p className="rounded-md border border-warning/40 bg-warning/10 px-3 py-2 text-sm text-warning">{wfStages.error}</p>) : null}
          {!wfStages?.skipped && !wfStages?.error && liveStagesList.length > 0 ? (<>
              <div className="space-y-1.5">
                <div className="flex items-center justify-between text-xs text-muted">
                  <span>Progress</span>
                  <span>
                    {jStarted} / {jTotal} stages touched
                  </span>
                </div>
                <div className="h-2 overflow-hidden rounded-full bg-muted">
                  <div className="h-full rounded-full bg-primary transition-[width] duration-500 ease-out" style={{ width: `${jProgressPct}%` }}/>
                </div>
              </div>
              <ul className="max-h-[min(28rem,56vh)] space-y-2 overflow-auto pr-1">
                {liveStagesList.map((stage: JenkinsPipelineStageRow, idx: number) => {
                const rowUi = jenkinsStageRowUi(stage.status);
                return (<li key={`${idx}-${stage.name}`} className={cn("flex items-start gap-3 rounded-lg border px-3 py-2.5 text-sm", rowUi.rowClass)}>
                      <div className="mt-0.5">{rowUi.icon}</div>
                      <div className="min-w-0 flex-1">
                        <p className="font-medium leading-snug text-foreground">{stage.name}</p>
                        <p className="mt-0.5 text-xs text-muted">Duration: {formatStageDurationMs(stage.durationMs)}</p>
                      </div>
                      <Badge variant={rowUi.badgeVariant} className="shrink-0 text-[10px] uppercase tracking-wide">
                        {rowUi.label}
                      </Badge>
                    </li>);
            })}
              </ul>
            </>) : null}
          {!wfStages?.skipped && !wfStages?.error && wfStages?.configured && liveStagesList.length === 0 && !pipelineStagesQuery.isLoading ? (<p className="text-sm text-muted">
              No stage breakdown returned for the current build (for example no <span className="font-mono text-xs">lastBuild</span> yet, or the job does not expose workflow stages).
            </p>) : null}
          <div className="border-t border-border pt-4">
            <p className="mb-2 text-xs font-semibold uppercase tracking-wider text-muted">Reference — expected steps in Jenkinsfile.paas-deploy</p>
            <p className="mb-3 text-xs text-muted">
              If Jenkins stops at Step 7, the controller job may be stale: pull the monorepo, enable inline sync, or rebuild the frontend image that bundles the Jenkinsfile.
            </p>
            <ol className="list-decimal space-y-1.5 pl-5 text-sm text-muted marker:text-foreground">
              {PAAS_DEPLOY_INCREMENTAL_JENKINS_STAGES.map((label) => (<li key={label} className="pl-1">
                  <span className="text-foreground">{label}</span>
                </li>))}
            </ol>
          </div>
        </CardContent>
      </Card>

      <section className="grid gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-1">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-base">
              <GitBranch className="h-5 w-5 text-primary"/>
              Jenkins
            </CardTitle>
            <CardDescription>
              Parameterized builds against your controller. Set{" "}
              <code className="rounded bg-muted/60 px-1">JENKINS_*</code> env vars for live integration.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="flex flex-wrap gap-2">
              <Button onClick={() => buildMutation.mutate()} disabled={buildMutation.isPending}>
                {buildMutation.isPending ? (<Loader2 className="mr-2 h-4 w-4 animate-spin"/>) : (<Wrench className="mr-2 h-4 w-4"/>)}
                Trigger build
              </Button>
              <Button onClick={() => deployMutation.mutate()} disabled={deployMutation.isPending}>
                {deployMutation.isPending ? (<Loader2 className="mr-2 h-4 w-4 animate-spin"/>) : (<Rocket className="mr-2 h-4 w-4"/>)}
                Full deploy
              </Button>
            </div>
            <Button variant="destructive" className="w-full sm:w-auto" onClick={() => rollbackMutation.mutate()} disabled={rollbackMutation.isPending}>
              {rollbackMutation.isPending ? (<Loader2 className="mr-2 h-4 w-4 animate-spin"/>) : (<RotateCcw className="mr-2 h-4 w-4"/>)}
              Rollback
            </Button>
          </CardContent>
        </Card>

        <Card className="lg:col-span-2">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-base">
              <Server className="h-5 w-5 text-primary"/>
              Argo CD
            </CardTitle>
            <CardDescription>
              Application health and sync state. Full deploy runs sync after gates and GitOps update.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            {argoQuery.isLoading ? (<Skeleton className="h-20 w-full"/>) : (<>
                <div className="flex flex-wrap items-center gap-2">
                  <span className="text-sm text-muted">Application</span>
                  <code className="rounded-md border border-border bg-muted/40 px-2 py-1 text-xs">
                    {argoQuery.data?.appName ?? "\u2014"}
                  </code>
                </div>
                <div className="flex flex-wrap gap-2">
                  <ArgoHealthBadge health={argoQuery.data?.health}/>
                  <Badge variant="outline">Sync: {argoQuery.data?.syncStatus ?? "\u2014"}</Badge>
                </div>
                {argoQuery.data?.unreachableReason ? (<p className="rounded-md border border-warning/40 bg-warning/10 px-3 py-2 text-xs text-warning">
                    {argoQuery.data.unreachableReason}
                  </p>) : null}
              </>)}
            <div className="rounded-lg border border-border bg-muted/20 p-3 text-xs text-muted">
              <p>
                Image in use:{" "}
                <span className="font-mono text-foreground/90">
                  {status?.imageTag || project.imageTag || "\u2014"}
                </span>
              </p>
            </div>
          </CardContent>
        </Card>
      </section>

      <section className="grid gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-base">
              <Shield className="h-5 w-5 text-primary"/>
              Security Analysis
            </CardTitle>
            <CardDescription>
              Dependency-Track metrics linked to the pipeline outcome so the dashboard shows build plus security, not just build alone.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="rounded-lg border border-border bg-muted/20 p-3 text-sm text-muted">
              <p className="font-medium text-foreground">{securityQuery.data?.summary ?? "Waiting for Dependency-Track metrics."}</p>
              {securityQuery.data?.projectUuid ? <p className="mt-2 font-mono text-xs">Dependency-Track UUID: {securityQuery.data.projectUuid}</p> : null}
            </div>
            <div className="grid gap-3 sm:grid-cols-4">
              <div className="rounded-lg border border-danger/30 bg-danger/5 p-3">
                <p className="text-xs uppercase tracking-wide text-muted">Critical</p>
                <p className="mt-2 text-2xl font-semibold text-danger">{securityMetrics?.critical ?? 0}</p>
              </div>
              <div className="rounded-lg border border-orange-500/30 bg-orange-500/5 p-3">
                <p className="text-xs uppercase tracking-wide text-muted">High</p>
                <p className="mt-2 text-2xl font-semibold text-orange-500">{securityMetrics?.high ?? 0}</p>
              </div>
              <div className="rounded-lg border border-yellow-500/30 bg-yellow-500/5 p-3">
                <p className="text-xs uppercase tracking-wide text-muted">Medium</p>
                <p className="mt-2 text-2xl font-semibold text-yellow-500">{securityMetrics?.medium ?? 0}</p>
              </div>
              <div className="rounded-lg border border-success/30 bg-success/5 p-3">
                <p className="text-xs uppercase tracking-wide text-muted">Low</p>
                <p className="mt-2 text-2xl font-semibold text-success">{securityMetrics?.low ?? 0}</p>
              </div>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-base">Build + Security</CardTitle>
            <CardDescription>Rough status for whoever is on-call.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            <div className="flex items-center justify-between rounded-lg border border-border px-3 py-2">
              <span className="text-muted">Build</span>
              <Badge variant={buildHeaderBadgeVariant(displayBuild)}>{displayBuild}</Badge>
            </div>
            <div className="flex items-center justify-between rounded-lg border border-border px-3 py-2">
              <span className="text-muted">Security</span>
              <Badge variant={(securityMetrics?.critical ?? 0) > 0 ? "danger" : (securityMetrics?.high ?? 0) > 0 ? "warning" : "success"}>
                {(securityMetrics?.critical ?? 0) > 0
            ? `${securityMetrics?.critical ?? 0} critical`
            : (securityMetrics?.high ?? 0) > 0
                ? `${securityMetrics?.high ?? 0} high`
                : "Clear"}
              </Badge>
            </div>
            <div className="flex items-center justify-between rounded-lg border border-border px-3 py-2">
              <span className="text-muted">Policy enforcement</span>
              <Badge variant={securityQuery.data?.findings ? ((securityMetrics?.critical ?? 0) > 0 ? "warning" : "success") : "outline"}>
                {(securityMetrics?.critical ?? 0) > 0 ? "Needs action" : "Validated"}
              </Badge>
            </div>
            <div className="rounded-lg border border-border bg-background/50 p-3">
              <p className="text-xs uppercase tracking-wide text-muted">Enforcement</p>
              <p className="mt-2 text-muted">
                {buildOk
            ? ((securityMetrics?.critical ?? 0) > 0
                ? `Build passed, but ${securityMetrics?.critical ?? 0} critical vulnerabilities still require action before production rollout.`
                : "Build passed and the security gate is clear for trusted deployment.")
            : "Run a build to refresh supply-chain and policy signals."}
              </p>
            </div>
            {securityQuery.data?.findings?.[0] ? <div className="rounded-lg border border-border bg-background/50 p-3">
                <p className="text-xs uppercase tracking-wide text-muted">What to fix</p>
                <p className="mt-2 font-medium text-foreground">{securityQuery.data.findings[0].title}</p>
                <p className="mt-1 text-muted">
                  {securityQuery.data.findings[0].recommendation || "Review the vulnerable component and upgrade to a patched version."}
                </p>
              </div> : null}
          </CardContent>
        </Card>
      </section>

      <div className="flex flex-wrap gap-2">
        <Button asChild variant="outline" size="sm">
          <Link href={`/projects/${projectId}`}>
            <ArrowLeft className="mr-2 h-4 w-4"/>
            Project
          </Link>
        </Button>
        <Button asChild variant="outline" size="sm">
          <Link href={`/docker/${projectId}`}>
            <Box className="mr-2 h-4 w-4"/>
            Docker
          </Link>
        </Button>
        <Button asChild variant="outline" size="sm">
          <Link href={`/security/${projectId}`}>
            <Shield className="mr-2 h-4 w-4"/>
            Security
          </Link>
        </Button>
        <Button asChild variant="outline" size="sm">
          <Link href={`/monitoring/${projectId}`}>
            <Activity className="mr-2 h-4 w-4"/>
            Monitoring
          </Link>
        </Button>
      </div>

      <section className="grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Build console</CardTitle>
            <CardDescription>Jenkins and compile output</CardDescription>
          </CardHeader>
          <CardContent>
            {statusQuery.isLoading ? (<Skeleton className="h-80 w-full"/>) : (<pre className={cn("max-h-80 overflow-auto rounded-lg border border-border p-4 text-xs leading-relaxed", "bg-background/80 font-mono")}>
              {status?.buildLogs?.trim() || "No build log text is stored on this project yet.\n\nRun Build from Operations. After Jenkins starts, this app syncs the job and the buffer fills here; you can also open the Cluster page \u2192 Platform logs for recent deployments across projects."}
              </pre>)}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-base">Deployment &amp; GitOps</CardTitle>
            <CardDescription>Registry, policy gates, Helm, and Argo CD trail</CardDescription>
          </CardHeader>
          <CardContent>
            {statusQuery.isLoading ? (<Skeleton className="h-80 w-full"/>) : (<pre className={cn("max-h-80 overflow-auto rounded-lg border border-border p-4 text-xs leading-relaxed", "bg-background/80 font-mono")}>
                {status?.deploymentLogs?.trim() ||
                "No deployment log text yet.\n\nRun Deploy after a successful build. GitOps/registry/policy steps append here when the controller updates the project; check /cluster for the latest stored buffer or Jenkins console fetch."}
              </pre>)}
          </CardContent>
        </Card>
      </section>
    </div>);
}
