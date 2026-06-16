"use client";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { LayoutGrid } from "lucide-react";
import { Button } from "@/components/ui/button";
import { ThemeToggle } from "@/components/layout/theme-toggle";
import { PipelineHelpTrigger } from "@/components/pipeline/pipeline-help-trigger";
import { useProjectIdFromRoute } from "@/hooks/use-project-id-from-route";
import { useAuth } from "@/hooks/use-auth";
export function TopNav() {
    const { user, logout } = useAuth();
    const router = useRouter();
    const projectId = useProjectIdFromRoute();
    const handleLogout = async () => {
        await logout();
        router.replace("/login");
    };
    return (<header className="sticky top-0 z-40 flex h-16 shrink-0 items-center justify-between border-b border-border bg-card/95 px-4 shadow-sm backdrop-blur-md supports-[backdrop-filter]:bg-card/80 lg:px-6">
      <div className="min-w-0 text-left">
        <p className="text-sm text-muted">Secure Delivery Platform</p>
        <p className="text-sm font-semibold">
          {user?.fullName} ({user?.role})
        </p>
      </div>
      <div className="flex items-center gap-2">
        {projectId ? <PipelineHelpTrigger projectId={projectId} variant="header" className="border-primary/40 bg-primary/10 text-foreground hover:bg-primary/20"/> : null}
        <Button variant="outline" size="sm" className="lg:hidden" asChild>
          <Link href="/integrations">
            <LayoutGrid className="h-4 w-4"/>
          </Link>
        </Button>
        <ThemeToggle />
        <Button variant="outline" type="button" onClick={handleLogout}>
          Logout
        </Button>
      </div>
    </header>);
}
