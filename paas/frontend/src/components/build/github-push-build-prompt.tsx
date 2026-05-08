"use client";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { Bell } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { pipelineApi } from "@/lib/api";
import { queryHttpData, queryHttpDetails, queryHttpMessage } from "@/lib/query-http-message";
import type { PendingGitHubPush } from "@/types";
export function GitHubPushBuildPrompt({ projectId, pending, projectBranch, gitCredentialsId }: {
    projectId: string;
    pending: PendingGitHubPush | null | undefined;
    projectBranch: string;
    gitCredentialsId?: string;
}) {
    const queryClient = useQueryClient();
    const [branch, setBranch] = useState(projectBranch);
    const [creds, setCreds] = useState(gitCredentialsId ?? "");
    useEffect(() => {
        if (pending) {
            setBranch((pending.branch || projectBranch).trim() || projectBranch);
            setCreds((gitCredentialsId ?? "").trim());
        }
    }, [pending, pending?.receivedAt, pending?.branch, projectBranch, gitCredentialsId]);
    const confirmMutation = useMutation({
        mutationFn: () => pipelineApi.triggerBuild(projectId, {
            branch: branch.trim() || undefined,
            ...(creds.trim() ? { gitCredentialsId: creds.trim() } : {})
        }),
        onSuccess: (data) => {
            queryClient.invalidateQueries({ queryKey: ["project", projectId] });
            queryClient.invalidateQueries({ queryKey: ["status", projectId] });
            toast.success(data.message || "Build triggered \u2014 Jenkins request sent from PaaS");
        },
        onError: (err: unknown) => {
            const msg = queryHttpMessage(err, "Could not trigger build");
            const details = queryHttpDetails(err);
            const data = queryHttpData(err);
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
    const dismissMutation = useMutation({
        mutationFn: () => pipelineApi.triggerBuild(projectId, { dismissPendingGitHubPush: true }),
        onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: ["project", projectId] });
            toast.success("Dismissed \u2014 you can trigger a build manually when ready.");
        },
        onError: (err: unknown) => {
            toast.error(queryHttpMessage(err, "Could not dismiss prompt"));
        }
    });
    if (!pending) {
        return null;
    }
    return (<Card className="border-amber-500/40 bg-amber-500/5">
            <CardHeader className="pb-2">
                <CardTitle className="flex items-center gap-2 text-base">
                    <Bell className="h-4 w-4 shrink-0"/>
                    Git push detected
                </CardTitle>
                <CardDescription>
                    {pending.fullName} @ <span className="font-mono text-xs">{pending.after.slice(0, 7)}</span>
                    {pending.cloneUrl ? (<>
                            {" "}
                            — <span className="break-all">{pending.cloneUrl}</span>
                        </>) : null}
                </CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
                <div className="grid gap-2 sm:grid-cols-2">
                    <div className="space-y-1.5">
                        <Label htmlFor={`gh-push-branch-${projectId}`}>Branch</Label>
                        <Input id={`gh-push-branch-${projectId}`} value={branch} onChange={(e) => setBranch(e.target.value)} placeholder={projectBranch}/>
                    </div>
                    <div className="space-y-1.5">
                        <Label htmlFor={`gh-push-creds-${projectId}`}>Jenkins Git credential ID (optional)</Label>
                        <Input id={`gh-push-creds-${projectId}`} value={creds} onChange={(e) => setCreds(e.target.value)} placeholder="e.g. github-pat"/>
                    </div>
                </div>
                <div className="flex flex-wrap gap-2">
                    <Button type="button" disabled={confirmMutation.isPending} onClick={() => confirmMutation.mutate()}>
                        {confirmMutation.isPending ? "Triggering\u2026" : "Trigger build"}
                    </Button>
                    <Button type="button" variant="outline" disabled={dismissMutation.isPending} onClick={() => dismissMutation.mutate()}>
                        Dismiss
                    </Button>
                </div>
            </CardContent>
        </Card>);
}
