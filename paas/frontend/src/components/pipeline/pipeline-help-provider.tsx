"use client";
import * as React from "react";
import { useQuery } from "@tanstack/react-query";
import { pipelineApi } from "@/lib/api";
import { useProjectIdFromRoute } from "@/hooks/use-project-id-from-route";
import { PipelineHelpModal } from "@/components/pipeline/pipeline-help-modal";

type RebuildState = {
    onRebuild?: () => void;
    rebuildPending?: boolean;
};

interface PipelineHelpContextValue {
    openHelp: (projectId: string) => void;
    setRebuild: (state: RebuildState | undefined) => void;
    routeHelpOverall: string | undefined;
}

const PipelineHelpContext = React.createContext<PipelineHelpContextValue | null>(null);

export function usePipelineHelp() {
    const ctx = React.useContext(PipelineHelpContext);
    if (!ctx) {
        throw new Error("usePipelineHelp must be used within PipelineHelpProvider");
    }
    return ctx;
}

export function usePipelineHelpRebuild(onRebuild?: () => void, rebuildPending?: boolean) {
    const { setRebuild } = usePipelineHelp();
    React.useEffect(() => {
        if (!onRebuild) {
            setRebuild(undefined);
            return () => setRebuild(undefined);
        }
        setRebuild({ onRebuild, rebuildPending });
        return () => setRebuild(undefined);
    }, [setRebuild, onRebuild, rebuildPending]);
}

export function PipelineHelpProvider({ children }: { children: React.ReactNode }) {
    const routeProjectId = useProjectIdFromRoute();
    const [open, setOpen] = React.useState(false);
    const [helpProjectId, setHelpProjectId] = React.useState<string | null>(null);
    const [rebuild, setRebuildState] = React.useState<RebuildState>({});
    const routeHelpQuery = useQuery({
        queryKey: ["pipeline-help", routeProjectId],
        queryFn: () => pipelineApi.getPipelineHelp(routeProjectId!),
        enabled: Boolean(routeProjectId),
        staleTime: 30_000
    });
    const setRebuild = React.useCallback((state: RebuildState | undefined) => {
        setRebuildState(state ?? {});
    }, []);
    const openHelp = React.useCallback((projectId: string) => {
        setHelpProjectId(projectId);
        setOpen(true);
    }, []);
    const activeProjectId = helpProjectId ?? routeProjectId;
    const value = React.useMemo(
        () => ({
            openHelp,
            setRebuild,
            routeHelpOverall: routeHelpQuery.data?.overall
        }),
        [openHelp, setRebuild, routeHelpQuery.data?.overall]
    );
    return (
        <PipelineHelpContext.Provider value={value}>
            {children}
            {activeProjectId ? (
                <PipelineHelpModal
                    projectId={activeProjectId}
                    open={open}
                    onOpenChange={(next) => {
                        setOpen(next);
                        if (!next) {
                            setHelpProjectId(null);
                        }
                    }}
                    onRebuild={rebuild.onRebuild}
                    rebuildPending={rebuild.rebuildPending}
                />
            ) : null}
        </PipelineHelpContext.Provider>
    );
}
