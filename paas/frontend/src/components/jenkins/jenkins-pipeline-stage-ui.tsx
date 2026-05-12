"use client";
import { CheckCircle2, Circle, Loader2, MinusCircle, SkipForward, XCircle } from "lucide-react";
export function formatStageDurationMs(ms: number | null): string {
    if (ms == null || ms < 0) {
        return "\u2014";
    }
    if (ms < 1000) {
        return `${ms}ms`;
    }
    const s = Math.round(ms / 1000);
    if (s < 60) {
        return `${s}s`;
    }
    const m = Math.floor(s / 60);
    const r = s % 60;
    return r > 0 ? `${m}m ${r}s` : `${m}m`;
}
export function shortJenkinsStageTitle(fullName: string): string {
    const t = fullName.replace(/^Step\s+\d+\s*[—–-]\s*/i, "").trim();
    return t.length > 0 ? t : fullName;
}
export function jenkinsStageStepIndexLabel(name: string, zeroBasedIndex: number): string {
    const m = /^Step\s+(\d+)/i.exec(name);
    if (m) {
        return m[1];
    }
    return String(zeroBasedIndex + 1);
}
export function jenkinsStageRowUi(status: string) {
    const u = status.toUpperCase();
    if (u === "SUCCESS") {
        return {
            icon: <CheckCircle2 className="h-5 w-5 shrink-0 text-success"/>,
            rowClass: "border-success/20 bg-success/5",
            badgeVariant: "success" as const,
            label: "Success",
            chipClass: "border-success/40 bg-success/15 text-success"
        };
    }
    if (u === "IN_PROGRESS" || u === "RUNNING" || u === "BUILDING") {
        return {
            icon: <Loader2 className="h-5 w-5 shrink-0 animate-spin text-primary"/>,
            rowClass: "border-primary/25 bg-primary/5",
            badgeVariant: "warning" as const,
            label: "Running",
            chipClass: "border-primary/50 bg-primary/10 text-primary"
        };
    }
    if (u === "FAILED" || u === "ABORTED") {
        return {
            icon: <XCircle className="h-5 w-5 shrink-0 text-danger"/>,
            rowClass: "border-danger/25 bg-danger/5",
            badgeVariant: "danger" as const,
            label: u === "ABORTED" ? "Aborted" : "Failed",
            chipClass: "border-danger/45 bg-danger/10 text-danger"
        };
    }
    if (u === "UNSTABLE" || u === "PAUSED_PENDING_INPUT") {
        return {
            icon: <MinusCircle className="h-5 w-5 shrink-0 text-warning"/>,
            rowClass: "border-warning/30 bg-warning/5",
            badgeVariant: "warning" as const,
            label: u === "PAUSED_PENDING_INPUT" ? "Paused" : "Unstable",
            chipClass: "border-warning/45 bg-warning/10 text-warning"
        };
    }
    if (u === "SKIPPED" || u === "NOT_EXECUTED" || u === "NOT_BUILT") {
        return {
            icon: <SkipForward className="h-5 w-5 shrink-0 text-muted"/>,
            rowClass: "border-border bg-muted/15",
            badgeVariant: "outline" as const,
            label: u === "NOT_EXECUTED" ? "Pending" : "Skipped",
            chipClass: "border-border bg-muted/30 text-muted-foreground"
        };
    }
    return {
        icon: <Circle className="h-5 w-5 shrink-0 text-muted"/>,
        rowClass: "border-border bg-muted/10",
        badgeVariant: "outline" as const,
        label: status || "Unknown",
        chipClass: "border-border bg-muted/20 text-muted-foreground"
    };
}
