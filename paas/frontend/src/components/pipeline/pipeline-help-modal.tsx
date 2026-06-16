"use client";
import * as React from "react";
import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { AlertCircle, CheckCircle2, HelpCircle, Info, Loader2, Sparkles } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog, DialogBody, DialogClose, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { pipelineApi } from "@/lib/api";
import type { PipelineHelpItem, PipelineHelpResponse, PipelineHelpSeverity } from "@/types";
import { cn } from "@/lib/utils";

function severityIcon(severity: PipelineHelpSeverity) {
    switch (severity) {
        case "error":
            return <AlertCircle className="h-5 w-5 shrink-0 text-danger"/>;
        case "warning":
            return <AlertCircle className="h-5 w-5 shrink-0 text-warning"/>;
        case "success":
            return <CheckCircle2 className="h-5 w-5 shrink-0 text-success"/>;
        default:
            return <Info className="h-5 w-5 shrink-0 text-primary"/>;
    }
}

function severityBannerClass(severity: PipelineHelpSeverity): string {
    switch (severity) {
        case "error":
            return "border-danger/30 bg-danger/10 text-danger";
        case "warning":
            return "border-warning/30 bg-warning/10 text-warning";
        case "success":
            return "border-success/30 bg-success/10 text-success";
        default:
            return "border-primary/30 bg-primary/10 text-primary";
    }
}

function HelpItemCard({ item, projectId }: {
    item: PipelineHelpItem;
    projectId: string;
}) {
    return (<article className={cn("rounded-xl border p-4", item.severity === "error" && "border-danger/25 bg-danger/5", item.severity === "warning" && "border-warning/25 bg-warning/5", item.severity === "success" && "border-success/25 bg-success/5", item.severity === "info" && "border-border/80 bg-muted/20")}>
            <div className="flex items-start gap-3">
                {severityIcon(item.severity)}
                <div className="min-w-0 flex-1 space-y-3">
                    <div className="flex flex-wrap items-center gap-2">
                        {item.stepLabel ? <Badge variant="outline" className="text-[10px] font-normal">
                                {item.stepLabel}
                            </Badge> : null}
                    </div>
                    <div className="space-y-2 text-sm">
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
                    {item.technicalDetail ? <details className="text-xs text-muted">
                            <summary className="cursor-pointer font-medium text-foreground/80">Technical detail</summary>
                            <p className="mt-2 font-mono text-[11px] leading-relaxed">{item.technicalDetail}</p>
                        </details> : null}
                    {item.action ? <div className="pt-1">
                            {item.action.kind === "edit_project" ? <Button asChild variant="outline" size="sm">
                                    <Link href={`/projects/${projectId}/edit`}>{item.action.label}</Link>
                                </Button> : null}
                            {item.action.kind === "security" ? <Button asChild variant="outline" size="sm">
                                    <Link href={`/security/${projectId}`}>{item.action.label}</Link>
                                </Button> : null}
                            {item.action.kind === "platform" ? <Button asChild variant="outline" size="sm">
                                    <Link href="/integrations">{item.action.label}</Link>
                                </Button> : null}
                        </div> : null}
                </div>
            </div>
        </article>);
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
    return (<Dialog open={open} onOpenChange={onOpenChange} className="max-w-2xl">
            <DialogClose onClose={() => onOpenChange(false)}/>
            <DialogHeader className="pr-12">
                <div className="flex items-center gap-2 text-primary">
                    <HelpCircle className="h-5 w-5"/>
                    <span className="text-xs font-semibold uppercase tracking-wider">Pipeline help</span>
                </div>
                {helpQuery.isLoading ? (<>
                        <Skeleton className="mt-2 h-6 w-48"/>
                        <Skeleton className="h-4 w-full max-w-md"/>
                    </>) : data ? (<>
                        <DialogTitle>{data.headline}</DialogTitle>
                        <DialogDescription>{data.summary}</DialogDescription>
                    </>) : (<DialogTitle>Something went wrong</DialogTitle>)}
            </DialogHeader>
            <DialogBody className="space-y-4">
                {helpQuery.isLoading ? (<div className="space-y-3">
                        <Skeleton className="h-32 w-full rounded-xl"/>
                        <Skeleton className="h-32 w-full rounded-xl"/>
                    </div>) : null}
                {helpQuery.isError ? (<div className="rounded-xl border border-danger/30 bg-danger/5 p-4 text-sm text-danger">
                        We could not load help for this project. Try again in a moment.
                    </div>) : null}
                {data ? (<>
                        <div className={cn("flex items-start gap-3 rounded-xl border px-4 py-3 text-sm", severityBannerClass(data.overall))}>
                            <Sparkles className="mt-0.5 h-4 w-4 shrink-0"/>
                            <div>
                                <p className="font-medium">{data.headline}</p>
                                <p className="mt-0.5 opacity-90">{data.summary}</p>
                                {data.jenkinsBuildNumber != null ? <p className="mt-2 text-xs opacity-80">
                                        Based on build #{data.jenkinsBuildNumber}
                                        {!data.hasLogs ? " · run a build for fresh advice" : ""}
                                    </p> : null}
                            </div>
                        </div>
                        <div className="space-y-3">
                            {data.items.map((item) => (<HelpItemCard key={item.id} item={item} projectId={projectId}/>))}
                        </div>
                        <p className="text-center text-xs text-muted">
                            Plain-language summary from your build log. Ask your admin for platform setup (Jenkins, Harbor, Sonar).
                        </p>
                    </>) : null}
            </DialogBody>
            <DialogFooter>
                {data?.items.some((i) => i.action?.kind === "rebuild") && onRebuild ? (<Button onClick={onRebuild} disabled={rebuildPending}>
                        {rebuildPending ? <Loader2 className="mr-2 h-4 w-4 animate-spin"/> : null}
                        Run a build
                    </Button>) : null}
                <Button variant="outline" onClick={() => onOpenChange(false)}>
                    Close
                </Button>
            </DialogFooter>
        </Dialog>);
}

interface PipelineHelpTriggerProps {
    projectId: string;
    variant?: "header" | "inline" | "icon" | "floating" | "table";
    className?: string;
    onRebuild?: () => void;
    rebuildPending?: boolean;
    attention?: boolean;
    label?: string;
}

export function PipelineHelpTrigger({ projectId, variant = "header", className, onRebuild, rebuildPending, attention, label }: PipelineHelpTriggerProps) {
    const [open, setOpen] = React.useState(false);
    const prefetchQuery = useQuery({
        queryKey: ["pipeline-help", projectId],
        queryFn: () => pipelineApi.getPipelineHelp(projectId),
        enabled: Boolean(projectId),
        staleTime: 30_000
    });
    const needsAttention = attention ?? (prefetchQuery.data?.overall === "error" || prefetchQuery.data?.overall === "warning");
    const buttonLabel = label ?? (variant === "inline" ? "Get help" : variant === "table" ? "Help" : "Pipeline help");
    return (<>
            <Button type="button" variant={variant === "inline" || variant === "floating" ? "default" : "outline"} size={variant === "icon" || variant === "table" ? "sm" : "sm"} className={cn(variant === "icon" && "h-8 w-8 p-0", variant === "table" && "h-8 gap-1 px-2.5", variant === "floating" && "h-12 gap-2 rounded-full bg-primary px-5 text-background shadow-lg ring-2 ring-primary/30 hover:bg-primary/90 hover:shadow-xl", variant !== "icon" && variant !== "table" && variant !== "floating" && "gap-2", needsAttention && variant !== "floating" && "border-warning/50 ring-1 ring-warning/30", needsAttention && variant === "floating" && "ring-warning/50", className)} onClick={() => setOpen(true)} title="Pipeline help" aria-label="Open pipeline help">
                <HelpCircle className={cn(variant === "floating" ? "h-5 w-5" : "h-4 w-4")}/>
                {variant === "icon" ? null : buttonLabel}
                {needsAttention && prefetchQuery.data?.overall === "error" && variant !== "icon" ? <Badge variant="danger" className="ml-0.5 text-[10px]">!</Badge> : null}
                {needsAttention && prefetchQuery.data?.overall === "warning" && variant !== "icon" ? <Badge variant="outline" className="ml-0.5 border-warning/50 text-[10px] text-warning">!</Badge> : null}
            </Button>
            <PipelineHelpModal projectId={projectId} open={open} onOpenChange={setOpen} onRebuild={onRebuild} rebuildPending={rebuildPending}/>
        </>);
}

// Re-export for typing in parent if needed
export type { PipelineHelpResponse };
