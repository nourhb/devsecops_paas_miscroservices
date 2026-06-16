export type PipelineHelpSeverity = "success" | "info" | "warning" | "error";

export type PipelineHelpActionKind = "edit_project" | "security" | "platform" | "rebuild";

export interface PipelineHelpAction {
    label: string;
    kind: PipelineHelpActionKind;
}

export interface PipelineHelpItem {
    id: string;
    severity: PipelineHelpSeverity;
    stepLabel?: string;
    happened: string;
    means: string;
    fix: string;
    technicalDetail?: string;
    action?: PipelineHelpAction;
}

export interface PipelineHelpResponse {
    projectId: string;
    deploymentId: string | null;
    jenkinsBuildNumber: number | null;
    overall: PipelineHelpSeverity;
    summary: string;
    headline: string;
    items: PipelineHelpItem[];
    hasLogs: boolean;
}
