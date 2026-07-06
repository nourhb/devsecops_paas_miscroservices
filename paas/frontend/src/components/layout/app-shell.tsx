"use client";
import { useEffect } from "react";
import { usePathname, useRouter } from "next/navigation";
import { SideNav } from "@/components/layout/side-nav";
import { TopNav } from "@/components/layout/top-nav";
import { PipelineHelpProvider } from "@/components/pipeline/pipeline-help";
import { TooltipProvider } from "@/components/ui/tooltip";
import { useAuth } from "@/hooks/use-auth";

export function AuthGuard({ children }: { children: React.ReactNode }) {
    const { isAuthenticated, loading } = useAuth();
    const router = useRouter();
    const pathname = usePathname();
    useEffect(() => {
        if (!loading && !isAuthenticated) {
            router.replace(`/login?next=${encodeURIComponent(pathname)}`);
        }
    }, [isAuthenticated, loading, pathname, router]);
    if (loading || !isAuthenticated) {
        return <div className="flex min-h-screen items-center justify-center text-muted">Loading platform...</div>;
    }
    return <>{children}</>;
}

export function AppShell({ children }: { children: React.ReactNode }) {
    return (
        <TooltipProvider delayDuration={280} skipDelayDuration={120}>
            <PipelineHelpProvider>
                <div className="min-h-screen bg-background text-foreground lg:flex">
                    <SideNav />
                    <div className="flex-1">
                        <TopNav />
                        <main className="p-4 lg:p-6">{children}</main>
                    </div>
                </div>
            </PipelineHelpProvider>
        </TooltipProvider>
    );
}
