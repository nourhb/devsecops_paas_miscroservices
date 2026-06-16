"use client";
import { CheckCircle2, AlertTriangle, SkipForward, XCircle, ClipboardList } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { PAAS_DEPLOY_INCREMENTAL_JENKINS_STAGES } from "@/lib/paas-deploy-jenkins-stages";
import type { PipelineStepCheckRow } from "@/lib/api";
import { cn } from "@/lib/utils";
export interface DeployVerifyRow {
    step: string;
    status: "OK" | "WARN" | "FAIL";
    detail: string;
}
function levelIcon(level: PipelineStepCheckRow["level"]) {
    if (level === "OK") {
        return <CheckCircle2 className="h-4 w-4 shrink-0 text-success"/>;
    }
    if (level === "WARN") {
        return <AlertTriangle className="h-4 w-4 shrink-0 text-warning"/>;
    }
    if (level === "SKIP") {
        return <SkipForward className="h-4 w-4 shrink-0 text-muted"/>;
    }
    return <XCircle className="h-4 w-4 shrink-0 text-danger"/>;
}
interface PipelineVerificationPanelProps {
    jenkinsChecks: PipelineStepCheckRow[];
    deployChecks: DeployVerifyRow[];
    buildComplete?: {
        result: string;
        image: string;
        project: string;
        build: string;
    } | null;
    artifactImage?: string | null;
}
export function PipelineVerificationPanel({ jenkinsChecks, deployChecks, buildComplete, artifactImage }: PipelineVerificationPanelProps) {
    const hasJenkins = jenkinsChecks.length > 0;
    const hasDeploy = deployChecks.length > 0;
    if (!hasJenkins && !hasDeploy && !buildComplete) {
        return null;
    }
    return (<Card>
            <CardHeader>
                <CardTitle className="flex items-center gap-2 text-base">
                    <ClipboardList className="h-5 w-5 text-primary"/>
                    Step verification (proof in logs)
                </CardTitle>
                <CardDescription>
                    Parsed from <span className="font-mono text-xs">PAAS_STEP_OK</span> in Jenkins and{" "}
                    <span className="font-mono text-xs">PAAS_DEPLOY_VERIFY</span> in PaaS deploy logs.
                </CardDescription>
            </CardHeader>
            <CardContent className="space-y-6">
                {buildComplete || artifactImage ? (<div className="rounded-lg border border-success/30 bg-success/5 px-3 py-2 text-sm">
                        <p className="font-medium text-foreground">Jenkins build complete</p>
                        <p className="mt-1 font-mono text-xs text-muted">
                            {buildComplete
                ? `result=${buildComplete.result} image=${buildComplete.image} #${buildComplete.build}`
                : `image=${artifactImage}`}
                        </p>
                    </div>) : null}
                {hasJenkins ? (<div>
                        <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">Jenkins steps (1–12)</p>
                        <ul className="space-y-2">
                            {PAAS_DEPLOY_INCREMENTAL_JENKINS_STAGES.map((label, idx) => {
                const stepNum = idx + 1;
                const rows = jenkinsChecks.filter((c) => c.step === stepNum);
                const worst = rows.find((r) => r.level === "FAIL")
                    ?? rows.find((r) => r.level === "WARN")
                    ?? rows.find((r) => r.level === "OK")
                    ?? rows.find((r) => r.level === "SKIP");
                const buildSucceeded = (buildComplete?.result || "").toUpperCase() === "SUCCESS";
                const inferredSkip = !worst && buildSucceeded && stepNum >= 8 && stepNum <= 11;
                return (<li key={label} className={cn("rounded-lg border px-3 py-2 text-sm", !worst && !inferredSkip && "border-border/60 bg-muted/10", worst?.level === "OK" && "border-success/25 bg-success/5", worst?.level === "WARN" && "border-warning/30 bg-warning/5", worst?.level === "SKIP" && "border-border bg-muted/15", worst?.level === "FAIL" && "border-danger/30 bg-danger/5", inferredSkip && "border-border bg-muted/15")}>
                                        <div className="flex items-start gap-2">
                                            {worst ? levelIcon(worst.level) : inferredSkip ? <SkipForward className="h-4 w-4 shrink-0 text-muted"/> : <span className="mt-0.5 h-4 w-4 rounded-full border border-dashed border-muted"/>}
                                            <div className="min-w-0 flex-1">
                                                <div className="flex flex-wrap items-center gap-2">
                                                    <span className="font-mono text-xs text-primary">Step {stepNum}</span>
                                                    {worst ? (<Badge variant={worst.level === "OK" ? "success" : worst.level === "FAIL" ? "danger" : "outline"} className="text-[10px]">
                                                            {worst.level}
                                                        </Badge>) : inferredSkip ? (<Badge variant="outline" className="text-[10px]">SKIP</Badge>) : (<Badge variant="outline" className="text-[10px]">No marker yet</Badge>)}
                                                </div>
                                                <p className="mt-0.5 text-xs text-muted">{label}</p>
                                                {inferredSkip && !worst ? (<p className="mt-1 font-mono text-[11px] leading-snug text-muted">Optional stage — no PAAS_STEP line in Jenkins console tail.</p>) : null}
                                                {rows.map((r) => (<p key={`${r.id}-${r.message}`} className="mt-1 font-mono text-[11px] leading-snug text-foreground/90">
                                                        [{r.id}] {r.message}
                                                    </p>))}
                                            </div>
                                        </div>
                                    </li>);
            })}
                        </ul>
                    </div>) : null}
                {hasDeploy ? (<div>
                        <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">PaaS post-build (GitOps + Argo)</p>
                        <ul className="space-y-2">
                            {deployChecks.map((row) => (<li key={`${row.step}-${row.detail}`} className={cn("flex items-start gap-2 rounded-lg border px-3 py-2 text-sm", row.status === "OK" && "border-success/25 bg-success/5", row.status === "WARN" && "border-warning/30 bg-warning/5", row.status === "FAIL" && "border-danger/30 bg-danger/5")}>
                                    {row.status === "OK" ? <CheckCircle2 className="h-4 w-4 shrink-0 text-success"/> : row.status === "WARN" ? <AlertTriangle className="h-4 w-4 shrink-0 text-warning"/> : <XCircle className="h-4 w-4 shrink-0 text-danger"/>}
                                    <div>
                                        <span className="font-medium">{row.step}</span>
                                        <p className="mt-0.5 font-mono text-xs text-muted">{row.detail}</p>
                                    </div>
                                </li>))}
                        </ul>
                    </div>) : null}
            </CardContent>
        </Card>);
}
