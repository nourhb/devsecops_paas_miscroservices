"use client";
import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { AlertCircle, CheckCircle2, HelpCircle, Info, Loader2 } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog, DialogBody, DialogClose, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { pipelineApi } from "@/lib/api";
import type { PipelineHelpItem, PipelineHelpSeverity } from "@/types";
import { cn } from "@/lib/utils";

function severityIcon(severity: PipelineHelpSeverity) {
    switch (severity) {
        case "error":
            return <AlertCircle className="h-5 w-5 shrink-0 text-danger" />;
        case "warning":
            return <AlertCircle className="h-5 w-5 shrink-0 text-warning" />;
        case "success":
            return <CheckCircle2 className="h-5 w-5 shrink-0 text-success" />;
        default:
            return <Info className="h-5 w-5 shrink-0 text-primary" />;
    }
}

function HelpItemCard({ item, projectId }: { item: PipelineHelpItem; projectId: string }) {
    return (
        <article
            dir="ltr"
            className={cn(
                "rounded-xl border p-4 text-left",
                item.severity === "error" && "border-danger/25 bg-danger/5",
                item.severity === "warning" && "border-warning/25 bg-warning/5",
                item.severity === "success" && "border-success/25 bg-success/5",
                item.severity === "info" && "border-border/80 bg-muted/20"
            )}
        >
            <div className="mb-3 flex items-center gap-2">
                {severityIcon(item.severity)}
                {item.stepLabel ? (
                    <Badge variant="outline" className="text-[10px] font-normal">
                        {item.stepLabel}
                    </Badge>
                ) : null}
            </div>
            <div className="space-y-3 text-sm">
                <div>
                    <p className="text-xs font-semibold uppercase tracking-wide text-muted">What happened</p>
                    <p className="mt-1 text-foreground">{item.happened}</p>
                </div>
                <div>
                    <p className="text-xs font-semibold uppercase tracking-wide text-muted">What it means</p>
                    <p className="mt-1 text-muted">{item.means}</p>
                </div>
                <div className="rounded-lg border border-border/60 bg-background/60 px-3 py-2.5">
                    <p className="text-xs font-semibold uppercase tracking-wide text-primary">What to do</p>
                    <p className="mt-1 text-sm font-medium text-foreground">{item.fix}</p>
                </div>
            </div>
            {item.technicalDetail ? (
                <details className="mt-3 text-xs text-muted">
                    <summary className="cursor-pointer font-medium text-foreground/80">Technical detail</summary>
                    <p className="mt-2 break-all font-mono text-[11px] leading-relaxed">{item.technicalDetail}</p>
                </details>
            ) : null}
            {item.action ? (
                <div className="mt-3">
                    {item.action.kind === "edit_project" ? (
                        <Button asChild variant="outline" size="sm">
                            <Link href={`/projects/${projectId}/edit`}>{item.action.label}</Link>
                        </Button>
                    ) : null}
                    {item.action.kind === "security" ? (
                        <Button asChild variant="outline" size="sm">
                            <Link href={`/security/${projectId}`}>{item.action.label}</Link>
                        </Button>
                    ) : null}
                    {item.action.kind === "platform" ? (
                        <Button asChild variant="outline" size="sm">
                            <Link href="/integrations">{item.action.label}</Link>
                        </Button>
                    ) : null}
                </div>
            ) : null}
        </article>
    );
}

interface PipelineHelpModalProps {
    projectId: string;
    open: boolean;
    onOpenChange: (open: boolean) => void;
    onRebuild?: () => void;
    rebuildPending?: boolean;
}

export function PipelineHelpModal({ projectId, open, onOpenChange, onRebuild, rebuildPending }: PipelineHelpModalProps) {
    const helpQuery = useQuery({
        queryKey: ["pipeline-help", projectId],
        queryFn: () => pipelineApi.getPipelineHelp(projectId),
        enabled: open && Boolean(projectId)
    });
    const data = helpQuery.data;
    const buildRef = data?.jenkinsBuildNumber != null ? `Build #${data.jenkinsBuildNumber}` : null;
    const items =
        data?.overall === "success" && data.items.length === 1 && data.items[0]?.id === "overall-success"
            ? []
            : data?.items ?? [];

    return (
        <Dialog open={open} onOpenChange={onOpenChange} className="paas-help-dialog max-w-2xl">
            <DialogClose onClose={() => onOpenChange(false)} />
            <DialogHeader className="pr-12">
                <div className="flex items-center gap-2 text-primary">
                    <HelpCircle className="h-5 w-5" />
                    <span className="text-xs font-semibold uppercase tracking-wider">Pipeline help</span>
                </div>
                {helpQuery.isLoading ? (
                    <>
                        <Skeleton className="mt-2 h-6 w-48" />
                        <Skeleton className="h-4 w-full max-w-md" />
                    </>
                ) : data ? (
                    <>
                        <DialogTitle>{data.headline}</DialogTitle>
                        <DialogDescription>
                            {data.summary}
                            {buildRef ? ` · ${buildRef}` : ""}
                        </DialogDescription>
                    </>
                ) : (
                    <DialogTitle>Could not load help</DialogTitle>
                )}
            </DialogHeader>
            <DialogBody className="space-y-3">
                {helpQuery.isLoading ? (
                    <div className="space-y-3">
                        <Skeleton className="h-32 w-full rounded-xl" />
                        <Skeleton className="h-32 w-full rounded-xl" />
                    </div>
                ) : null}
                {helpQuery.isError ? (
                    <p className="rounded-xl border border-danger/30 bg-danger/5 p-4 text-sm text-danger">
                        We could not load help for this project. Try again in a moment.
                    </p>
                ) : null}
                {data ? (
                    <div className="space-y-3">
                        {items.length > 0 ? (
                            items.map((item) => <HelpItemCard key={item.id} item={item} projectId={projectId} />)
                        ) : (
                            <p className="text-sm text-muted">No extra steps required for this run.</p>
                        )}
                    </div>
                ) : null}
            </DialogBody>
            <DialogFooter>
                {data?.items.some((i) => i.action?.kind === "rebuild") && onRebuild ? (
                    <Button onClick={onRebuild} disabled={rebuildPending}>
                        {rebuildPending ? <Loader2 className="mr-2 h-4 w-4 animate-spin" /> : null}
                        Run a build
                    </Button>
                ) : null}
                <Button variant="outline" onClick={() => onOpenChange(false)}>
                    Close
                </Button>
            </DialogFooter>
        </Dialog>
    );
}
