"use client";
import { SideNav } from "@/components/layout/side-nav";
import { TopNav } from "@/components/layout/top-nav";
import { PipelineHelpProvider } from "@/components/pipeline/pipeline-help-provider";
import { TooltipProvider } from "@/components/ui/tooltip";

export function AppShell({ children }: {
    children: React.ReactNode;
}) {
    return (<TooltipProvider delayDuration={280} skipDelayDuration={120}>
      <PipelineHelpProvider>
        <div className="min-h-screen bg-background text-foreground lg:flex">
          <SideNav />
          <div className="flex-1">
            <TopNav />
            <main className="p-4 lg:p-6">{children}</main>
          </div>
        </div>
      </PipelineHelpProvider>
    </TooltipProvider>);
}
