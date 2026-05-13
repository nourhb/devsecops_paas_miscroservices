"use client";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { LayoutGrid } from "lucide-react";
import { Button } from "@/components/ui/button";
import { ThemeToggle } from "@/components/layout/theme-toggle";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { useAuth } from "@/hooks/use-auth";
import { hints } from "@/lib/app-hints";
export function TopNav() {
    const { user, logout } = useAuth();
    const router = useRouter();
    const handleLogout = async () => {
        await logout();
        router.replace("/login");
    };
    return (<header className="sticky top-0 z-40 flex h-16 shrink-0 items-center justify-between border-b border-border bg-card/95 px-4 shadow-sm backdrop-blur-md supports-[backdrop-filter]:bg-card/80 lg:px-6">
      <Tooltip delayDuration={300}>
        <TooltipTrigger asChild>
          <div className="min-w-0 cursor-default text-left">
            <p className="text-sm text-muted">Secure Delivery Platform</p>
            <p className="text-sm font-semibold">
              {user?.fullName} ({user?.role})
            </p>
          </div>
        </TooltipTrigger>
        <TooltipContent side="bottom" align="start" className="max-w-xs">
          {hints.topNav.userLine}
        </TooltipContent>
      </Tooltip>
      <div className="flex items-center gap-2">
        <Tooltip delayDuration={300}>
          <TooltipTrigger asChild>
            <span className="inline-flex">
              <Button variant="outline" size="sm" className="lg:hidden" asChild>
                <Link href="/integrations">
                  <LayoutGrid className="h-4 w-4"/>
                </Link>
              </Button>
            </span>
          </TooltipTrigger>
          <TooltipContent>{hints.topNav.mobileHub}</TooltipContent>
        </Tooltip>
        <ThemeToggle />
        <Tooltip delayDuration={300}>
          <TooltipTrigger asChild>
            <Button variant="outline" type="button" onClick={handleLogout}>
              Logout
            </Button>
          </TooltipTrigger>
          <TooltipContent className="max-w-xs">{hints.topNav.logout}</TooltipContent>
        </Tooltip>
      </div>
    </header>);
}
