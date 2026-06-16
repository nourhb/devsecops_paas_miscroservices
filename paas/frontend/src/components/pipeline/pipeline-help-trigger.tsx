"use client";
import * as React from "react";
import { HelpCircle } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { usePipelineHelp } from "@/components/pipeline/pipeline-help-provider";
import { useProjectIdFromRoute } from "@/hooks/use-project-id-from-route";
import { cn } from "@/lib/utils";

interface PipelineHelpTriggerProps {
    projectId: string;
    variant?: "header" | "inline" | "icon" | "table";
    className?: string;
    attention?: boolean;
    label?: string;
}

export function PipelineHelpTrigger({
    projectId,
    variant = "header",
    className,
    attention,
    label
}: PipelineHelpTriggerProps) {
    const { openHelp, routeHelpOverall } = usePipelineHelp();
    const routeProjectId = useProjectIdFromRoute();
    const onRoute = projectId === routeProjectId;
    const needsAttention =
        attention ??
        (onRoute && (routeHelpOverall === "error" || routeHelpOverall === "warning"));
    const buttonLabel = label ?? (variant === "inline" ? "Get help" : variant === "table" ? "Help" : "Pipeline help");

    return (
        <Button
            type="button"
            variant={variant === "inline" ? "default" : "outline"}
            size="sm"
            className={cn(
                variant === "icon" && "h-8 w-8 p-0",
                variant === "table" && "h-8 gap-1 px-2.5",
                variant !== "icon" && variant !== "table" && "gap-2",
                needsAttention && "border-warning/50 ring-1 ring-warning/30",
                className
            )}
            onClick={() => openHelp(projectId)}
            title="Pipeline help"
            aria-label="Open pipeline help"
        >
            <HelpCircle className="h-4 w-4" />
            {variant === "icon" ? null : buttonLabel}
            {needsAttention && routeHelpOverall === "error" && variant !== "icon" ? (
                <Badge variant="danger" className="ml-0.5 text-[10px]">
                    !
                </Badge>
            ) : null}
            {needsAttention && routeHelpOverall === "warning" && variant !== "icon" ? (
                <Badge variant="outline" className="ml-0.5 border-warning/50 text-[10px] text-warning">
                    !
                </Badge>
            ) : null}
        </Button>
    );
}
