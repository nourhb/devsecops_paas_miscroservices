"use client";
import { useProjectIdFromRoute } from "@/hooks/use-project-id-from-route";
import { PipelineHelpTrigger } from "@/components/pipeline/pipeline-help-modal";

/**
 * Floating pipeline help — visible on every project-scoped page (including deployments).
 */
export function ProjectPipelineHelpDock() {
    const projectId = useProjectIdFromRoute();
    if (!projectId) {
        return null;
    }
    return (<div className="pointer-events-none fixed bottom-5 right-5 z-[100] sm:bottom-6 sm:right-6">
            <div className="pointer-events-auto">
                <PipelineHelpTrigger projectId={projectId} variant="floating" attention/>
            </div>
        </div>);
}
