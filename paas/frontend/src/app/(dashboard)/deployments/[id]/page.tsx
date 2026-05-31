"use client";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { ArrowLeft, ChevronRight, ClipboardList, ExternalLink, Hash, Loader2, StopCircle } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { DeploymentPipelinePreview } from "@/components/deployments/deployment-pipeline-preview";
import { DeploymentLogsView, deploymentFailureStageLabel, jenkinsScmCloneFailureHint } from "@/components/deployments/deployment-logs-view";
import { Hint } from "@/components/hint";
import { shouldSkipAppReachabilityProbe } from "@/lib/app-reachability";
import { pipelineApi, projectApi } from "@/lib/api";
import { hints } from "@/lib/app-hints";
import { queryHttpMessage } from "@/lib/query-http-message";
function deploymentStatusVariant(status: string): "success" | "danger" | "warning" {
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
export default function DeploymentDetailPage() {
    const params = useParams<{
        id: string;
    }>();
    const deploymentId = params.id;
    const queryClient = useQueryClient();
    const query = useQuery({
        queryKey: ["deployment", deploymentId],
        queryFn: () => pipelineApi.getDeployment(deploymentId),
        refetchInterval: (q) => {
            const s = q.state.data?.status?.toUpperCase();
            return s === "PENDING" || s === "DEPLOYING" ? 4000 : false;
        }
    });
    const cancelMutation = useMutation({
        mutationFn: () => pipelineApi.cancelDeployment(deploymentId),
        onSuccess: (data) => {
            void queryClient.invalidateQueries({ queryKey: ["deployment", deploymentId] });
            void queryClient.invalidateQueries({ queryKey: ["project", query.data?.projectId] });
            void queryClient.invalidateQueries({ queryKey: ["status", query.data?.projectId] });
            toast.success(data.message || "Cancellation sent to Jenkins.");
        },
        onError: (e: unknown) => {
            toast.error(queryHttpMessage(e, "Could not cancel deployment."));
        }
    });
    const reachQuery = useQuery({
        queryKey: ["app-reachability", query.data?.projectId],
        queryFn: () => projectApi.getAppReachability(query.data!.projectId),
        enabled: Boolean(query.data?.url && query.data?.projectId) && !shouldSkipAppReachabilityProbe(query.data?.url),
        refetchInterval: 15000
    });
    if (query.isLoading) {
        return (<div className="space-y-6">
        <Skeleton className="h-4 w-56"/>
        <Skeleton className="h-10 w-2/3 max-w-md"/>
        <Skeleton className="h-96 w-full"/>
      </div>);
    }
    if (query.isError || !query.data) {
        return (<Card className="border-danger/30">
        <CardHeader>
          <CardTitle>Deployment not found</CardTitle>
          <CardDescription>You may not have access, or the ID is invalid.</CardDescription>
        </CardHeader>
        <CardContent>
          <Button variant="outline" asChild>
            <Link href="/projects">
              <ArrowLeft className="mr-2 h-4 w-4"/>
              Back to projects
            </Link>
          </Button>
        </CardContent>
      </Card>);
    }
    const d = query.data;
    const live = query.isFetching && !query.isLoading;
    const canCancelJenkins = ["PENDING", "DEPLOYING"].includes(d.status.toUpperCase()) && (!d.buildProvider || d.buildProvider === "jenkins");
    const isFailed = d.status.toUpperCase() === "FAILED";
    const jenkinsHint = isFailed ? jenkinsScmCloneFailureHint(d.logs ?? "") : null;
    return (<div className="space-y-8">
      <nav className="flex flex-wrap items-center gap-1 text-sm text-muted">
        <Link href="/projects" className="hover:text-foreground">
          Projects
        </Link>
        <ChevronRight className="h-4 w-4 shrink-0 opacity-60"/>
        <Link href={`/projects/${d.projectId}`} className="hover:text-foreground">
          Project
        </Link>
        <ChevronRight className="h-4 w-4 shrink-0 opacity-60"/>
        <span className="truncate font-mono text-xs text-foreground">Deployment</span>
      </nav>

      <header className="flex flex-col gap-4 border-b border-border pb-8 sm:flex-row sm:items-start sm:justify-between">
        <div className="space-y-2">
          <div className="flex items-center gap-2 text-primary">
            <ClipboardList className="h-7 w-7 shrink-0" aria-hidden/>
            <span className="text-xs font-semibold uppercase tracking-wider">Deployment</span>
          </div>
          <h1 className="flex flex-wrap items-center gap-2 font-mono text-xl font-semibold tracking-tight sm:text-2xl">
            {d.id}
            <Hint side="bottom">{hints.deployment.deployId}</Hint>
          </h1>
          <p className="text-xs text-muted">
            Auto-refresh while running (~4s); otherwise on focus
            {live ? (<span className="ml-2 inline-flex items-center gap-1">
                <Loader2 className="h-3 w-3 animate-spin"/>
                Updating…
              </span>) : null}
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Badge className="h-9 gap-1.5 px-3 py-1.5" variant={deploymentStatusVariant(d.status)}>
            {["PENDING", "DEPLOYING"].includes(d.status.toUpperCase()) ? (<Loader2 className="h-3.5 w-3.5 shrink-0 animate-spin" aria-hidden/>) : null}
            {d.status}
          </Badge>
          <Badge variant="outline" className="h-9 gap-1.5 px-3 py-1.5 font-mono text-xs">
            <Hash className="h-3.5 w-3.5"/>
            Run {d.buildRunId ?? d.buildNumber ?? "\u2014"}
          </Badge>
          {d.buildProvider ? <Badge variant="outline" className="h-9 px-3 py-1.5">{d.buildProvider}</Badge> : null}
          {canCancelJenkins ? (<Button type="button" variant="outline" className="h-9 border-warning/40 text-warning hover:bg-warning/10" disabled={cancelMutation.isPending} onClick={() => cancelMutation.mutate()}>
              {cancelMutation.isPending ? (<Loader2 className="mr-2 h-4 w-4 animate-spin"/>) : (<StopCircle className="mr-2 h-4 w-4"/>)}
              Cancel Jenkins run
            </Button>) : null}
        </div>
      </header>

      {isFailed ? (<Card className="border-danger/50 bg-danger/10">
          <CardHeader className="pb-2">
            <CardTitle className="text-base text-danger flex flex-wrap items-center gap-2">
              Deployment failed
              <Hint>{hints.deployment.failedCallout}</Hint>
            </CardTitle>
            <CardDescription className="text-danger/90">
              {d.failureReason ? (<>
                  <span className="font-semibold text-foreground">
                    {deploymentFailureStageLabel(d.failureReason)}
                  </span>
                  {d.failureMessage ? (<>
                      {" \u2014 "}
                      <span className="text-foreground/90">{d.failureMessage}</span>
                    </>) : null}
                </>) : d.failureMessage ? (<span className="text-foreground/90">{d.failureMessage}</span>) : ("See console output below for details.")}
            </CardDescription>
          </CardHeader>
        </Card>) : null}

      {d.url ? (<Card>
          <CardHeader>
            <CardTitle className="text-base flex flex-wrap items-center gap-2">
              Live application
              <Hint>{hints.deployment.liveApp}</Hint>
            </CardTitle>
            <CardDescription>URL recorded when this deployment reached DEPLOYED.</CardDescription>
          </CardHeader>
          <CardContent className="flex flex-col gap-3 sm:flex-row sm:flex-wrap sm:items-center">
            <a href={d.url} target="_blank" rel="noopener noreferrer" className="break-all font-mono text-sm text-primary hover:underline">
              {d.url}
            </a>
            <Button variant="outline" size="sm" asChild>
              <a href={d.url} target="_blank" rel="noopener noreferrer">
                <ExternalLink className="mr-2 h-4 w-4"/>
                Open app
              </a>
            </Button>
            {reachQuery.data?.reachable ? (<Badge variant="success">
                Reachable · {reachQuery.data.statusCode ?? "?"}
              </Badge>) : reachQuery.data && !reachQuery.data.reachable && reachQuery.data.error !== "no_url" && reachQuery.data.error !== "synthetic_local" ? (<Badge variant="warning">
                Probe failed / timeout
              </Badge>) : reachQuery.isFetching ? (<Badge variant="outline">Probing…</Badge>) : null}
          </CardContent>
        </Card>) : null}

      {d.artifactImage ? (<Card>
          <CardHeader>
            <CardTitle className="text-base flex flex-wrap items-center gap-2">
              Artifact
              <Hint>{hints.deployment.artifact}</Hint>
            </CardTitle>
            <CardDescription>Image produced by the build backend for this deployment.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-2 font-mono text-xs">
            <p className="break-all">{d.artifactImage}</p>
            {d.artifactDigest ? <p className="break-all text-muted">{d.artifactDigest}</p> : null}
          </CardContent>
        </Card>) : null}

      <DeploymentPipelinePreview buildNumber={d.buildNumber} buildProvider={d.buildProvider} deploymentStatus={d.status} projectId={d.projectId} deploymentLogs={d.logs}/>

      <Card>
        <CardHeader>
          <CardTitle className="text-base flex flex-wrap items-center gap-2">
            Console output
            <Hint>{hints.deployment.console}</Hint>
          </CardTitle>
          <CardDescription>
            Last 5000 characters; error lines are highlighted in red when the deployment failed.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          {jenkinsHint ? (<div className="rounded-lg border border-primary/40 bg-primary/10 p-4 text-sm text-foreground">
              <p className="font-medium text-primary">What this usually means</p>
              <p className="mt-2 leading-relaxed text-foreground/90">{jenkinsHint}</p>
            </div>) : null}
          <DeploymentLogsView logs={d.logs ?? ""} failed={isFailed}/>
        </CardContent>
      </Card>

      <Button variant="outline" asChild>
        <Link href={`/projects/${d.projectId}`}>
          <ArrowLeft className="mr-2 h-4 w-4"/>
          Back to project
        </Link>
      </Button>
    </div>);
}
