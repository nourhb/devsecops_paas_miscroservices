"use client";
import { useEffect, useRef } from "react";
import { cn } from "@/lib/utils";
const ERROR_LINE = /(FAILED|FAILURE|\bERROR\b|error:|Exception|HTTP\s[45]\d{2}|\[gitops\]\s+FAILED|\[argocd\]\s+FAILED|\[jenkins-monitor\]|Timed out|rejected the deploy)/i;
export function DeploymentLogsView({ logs, failed }: {
    logs: string;
    failed: boolean;
}) {
    const lines = logs.trim().length > 0 ? logs.split("\n") : ["No logs yet."];
    const preRef = useRef<HTMLPreElement>(null);
    useEffect(() => {
        const el = preRef.current;
        if (el) {
            el.scrollTop = el.scrollHeight;
        }
    }, [logs]);
    return (<pre ref={preRef} className={cn("max-h-[min(70vh,32rem)] overflow-auto rounded-lg border p-4 text-xs leading-relaxed", "whitespace-pre-wrap break-all font-mono", failed
            ? "border-danger/50 bg-danger/10 text-foreground"
            : "border-border bg-background/80 text-foreground/90")}>
      {lines.map((line, i) => (<span key={i} className={cn("block", failed && ERROR_LINE.test(line) ? "font-medium text-danger" : failed ? "text-foreground/85" : "")}>
          {line.length ? line : " "}
        </span>))}
    </pre>);
}
export function deploymentFailureStageLabel(reason: string | null | undefined): string {
    if (!reason) {
        return "";
    }
    const labels: Record<string, string> = {
        JENKINS: "Build backend",
        GITOPS: "GitOps",
        ARGOCD: "Argo CD",
        IMAGE_REF: "Image configuration",
        TRIGGER: "Deploy trigger",
        TIMEOUT: "Timeout",
        UNKNOWN: "Unknown"
    };
    return labels[reason] ?? reason;
}
