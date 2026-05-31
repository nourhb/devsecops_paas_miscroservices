"use client";
import { useQuery } from "@tanstack/react-query";
import { ExternalLink, Loader2, Workflow } from "lucide-react";
import { jenkinsStageRowUi, jenkinsStageStepIndexLabel, shortJenkinsStageTitle, formatStageDurationMs } from "@/components/jenkins/jenkins-pipeline-stage-ui";
import { buildPaasDeployDisplayStages } from "@/lib/paas-deploy-jenkins-stages";
import { parsePipelineVerificationLogs } from "@/server/jenkins/pipeline-step-verification";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { jenkinsUi, type JenkinsPipelineStageRow } from "@/lib/api";
import { jenkinsUrlForBrowser } from "@/lib/jenkins-browser-url";
import { cn } from "@/lib/utils";
type DeploymentPipelinePreviewProps = {
    projectId: string;
    buildNumber: number | null;
    buildProvider: string | null;
    deploymentStatus: string;
    deploymentLogs?: string | null;
};
export function DeploymentPipelinePreview({ projectId, buildNumber, buildProvider, deploymentStatus, deploymentLogs }: DeploymentPipelinePreviewProps) {
    const isJenkins = !buildProvider || buildProvider === "jenkins";
    const statusU = deploymentStatus.toUpperCase();
    const deployBusy = statusU === "PENDING" || statusU === "DEPLOYING";
    const stagesQuery = useQuery({
        queryKey: ["jenkins-pipeline-stages", projectId, buildNumber ?? "latest"],
        queryFn: ({ signal }) => jenkinsUi.pipelineStages(projectId, buildNumber ?? undefined, signal),
        enabled: isJenkins && Boolean(projectId.trim()),
        refetchInterval: (q) => {
            const building = Boolean(q.state.data?.building);
            if (deployBusy || building) {
                return 4000;
            }
            return 20000;
        }
    });
    if (!isJenkins) {
        return null;
    }
    const data = stagesQuery.data;
    const jenkinsHref = jenkinsUrlForBrowser(data?.buildUrl, {
        buildNumber: data?.buildNumber ?? buildNumber
    });
    const deployChecks = deploymentLogs ? parsePipelineVerificationLogs(deploymentLogs).deployChecks : [];
    const displayStages = buildPaasDeployDisplayStages(data?.stages ?? [], data ?? undefined, deployChecks, deploymentStatus);
    const stages: JenkinsPipelineStageRow[] = displayStages;
    const started = stages.filter((s) => s.status.toUpperCase() !== "NOT_EXECUTED").length;
    const total = stages.length;
    const progressPct = total > 0 ? Math.min(100, Math.round(started / total * 100)) : 0;
    return (<Card>
      <CardHeader className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="space-y-1">
          <div className="flex items-center gap-2 text-primary">
            <Workflow className="h-5 w-5 shrink-0"/>
            <CardTitle className="text-base">Pipeline preview</CardTitle>
          </div>
          <CardDescription>
            Live Jenkins workflow stages for this deployment
            {buildNumber != null ? (<>
                {" "}
                (build <span className="font-mono text-foreground/80">#{buildNumber}</span>)
              </>) : (" (current job run if no build number yet)")}.
          </CardDescription>
          {data && !data.skipped ? (<div className="flex flex-wrap gap-2 pt-1">
              {data.buildNumber != null ? <Badge variant="outline" className="font-mono text-[10px]">Jenkins #{data.buildNumber}</Badge> : null}
              {data.runStatus ? <Badge variant="outline" className="text-[10px]">Workflow: {data.runStatus}</Badge> : null}
              {data.result ? <Badge variant="outline" className="text-[10px]">Result: {data.result}</Badge> : null}
              {data.building ? <Badge variant="warning" className="gap-1 text-[10px]">
                  <Loader2 className="h-3 w-3 animate-spin"/>
                  Building
                </Badge> : null}
            </div>) : null}
        </div>
        {jenkinsHref ? (<Button variant="outline" size="sm" className="shrink-0" asChild>
            <a href={jenkinsHref} target="_blank" rel="noopener noreferrer">
              <ExternalLink className="mr-2 h-4 w-4"/>
              Open in Jenkins
            </a>
          </Button>) : null}
      </CardHeader>
      <CardContent className="space-y-4">
        {deployChecks.some((check) => check.status === "FAIL") ? (<p className="rounded-md border border-danger/35 bg-danger/10 px-3 py-2 text-sm text-danger">
            Jenkins finished successfully, but PaaS post-deploy verification failed (GitOps, Argo CD, or URL probe). See console output below.
          </p>) : null}
        {stagesQuery.isError ? (<p className="rounded-md border border-danger/35 bg-danger/10 px-3 py-2 text-sm text-danger">
            Could not load pipeline stages. Console output below may still show progress.
          </p>) : null}
        {data?.skipped ? (<p className="text-sm text-muted">{data.reason || "Jenkins stages are not available."}</p>) : null}
        {data?.error ? (<p className="rounded-md border border-warning/40 bg-warning/10 px-3 py-2 text-sm text-warning">{data.error}</p>) : null}
        {data?.wfapiHint ? (<p className={`rounded-md border px-3 py-2 text-sm leading-relaxed ${data.error ? "mt-2 border-border bg-muted/20 text-muted" : "border-primary/35 bg-primary/10 text-foreground/90"}`}>
            {data.wfapiHint}
          </p>) : null}
        {!data?.skipped && stages.length > 0 ? (<>
            <div className="space-y-1.5">
              <div className="flex items-center justify-between text-xs text-muted">
                <span>Stage progress</span>
                <span className="tabular-nums">
                  {started} / {total} reached
                </span>
              </div>
              <div className="h-2 overflow-hidden rounded-full bg-muted">
                <div className="h-full rounded-full bg-primary transition-[width] duration-500 ease-out" style={{ width: `${progressPct}%` }}/>
              </div>
            </div>
            <div className="relative -mx-1">
              <div className="flex gap-2 overflow-x-auto pb-2 pt-1 [scrollbar-width:thin]">
                {stages.map((stage, idx) => {
                const ui = jenkinsStageRowUi(stage.status);
                const idxLabel = jenkinsStageStepIndexLabel(stage.name, idx);
                const title = shortJenkinsStageTitle(stage.name);
                return (<div key={`${idx}-${stage.name}`} className="flex min-w-[5.5rem] max-w-[7.5rem] shrink-0 flex-col items-center gap-1.5 text-center">
                    <div className={cn("flex h-9 w-9 shrink-0 items-center justify-center rounded-full border-2 text-xs font-semibold tabular-nums", ui.chipClass)}>
                      {idxLabel}
                    </div>
                    <p className="line-clamp-3 text-[10px] font-medium leading-snug text-foreground" title={stage.name}>
                      {title}
                    </p>
                    <span className="text-[9px] text-muted tabular-nums">{formatStageDurationMs(stage.durationMs)}</span>
                  </div>);
            })}
              </div>
            </div>
          </>) : null}
        {!data?.skipped && !data?.error && data?.configured && stages.length === 0 && !stagesQuery.isLoading ? (<p className="text-sm text-muted">
            No stage breakdown for this run yet. If the job just started, wait a few seconds; otherwise the controller may not expose workflow stages for this build.
          </p>) : null}
        {stagesQuery.isFetching && !stagesQuery.isLoading ? (<p className="flex items-center gap-1.5 text-xs text-muted">
            <Loader2 className="h-3 w-3 animate-spin"/>
            Updating stages…
          </p>) : null}
      </CardContent>
    </Card>);
}
