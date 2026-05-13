"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { FolderKanban, LayoutDashboard, LayoutGrid, Package, PlusCircle, ServerCog, Boxes, UserRound } from "lucide-react";
import { hints } from "@/lib/app-hints";
import { cn } from "@/lib/utils";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
const primaryNav = [
    { href: "/dashboard", label: "Dashboard", icon: LayoutDashboard, prefix: "/dashboard", hint: hints.nav.dashboard },
    { href: "/integrations", label: "Platform hub", icon: LayoutGrid, prefix: "/integrations", hint: hints.nav.platformHub },
    { href: "/cluster", label: "Cluster status", icon: ServerCog, prefix: "/cluster", exact: true, hint: hints.nav.cluster },
    { href: "/cluster/namespaces", label: "K8s namespaces", icon: Boxes, prefix: "/cluster/namespaces", hint: hints.nav.clusterNamespaces },
    { href: "/artifacts", label: "Artifacts", icon: Package, prefix: "/artifacts", hint: hints.nav.artifacts },
    { href: "/projects", label: "Projects", icon: FolderKanban, prefix: "/projects", hint: hints.nav.projects },
    { href: "/projects/create", label: "New project", icon: PlusCircle, prefix: "/projects/create", hint: hints.nav.newProject },
    { href: "/account", label: "Account", icon: UserRound, prefix: "/account", hint: hints.nav.account }
] as const;
export function SideNav() {
    const pathname = usePathname();
    return (<aside className="hidden w-64 shrink-0 border-r border-border bg-card p-4 lg:sticky lg:top-0 lg:block lg:h-screen lg:max-h-screen lg:overflow-y-auto lg:self-start">
      <div className="mb-8">
        <p className="text-xs uppercase tracking-widest text-muted">DevSecOps PaaS</p>
        <h1 className="text-2xl font-semibold">Control Plane</h1>
      </div>
      <nav className="space-y-2">
        {primaryNav.map((item) => {
            const Icon = item.icon;
            const active = item.prefix === "/projects"
                ? pathname.startsWith("/projects") && pathname !== "/projects/create"
                : item.prefix === "/account"
                    ? pathname === "/account" || pathname.startsWith("/account/")
                    : "exact" in item && item.exact
                    ? pathname === item.href
                    : pathname === item.href || pathname.startsWith(item.prefix + "/");
            return (<Tooltip key={item.href} delayDuration={320}>
              <TooltipTrigger asChild>
                <Link href={item.href} className={cn("flex items-center gap-3 rounded-md px-3 py-2 text-sm transition-colors", active ? "bg-primary text-background" : "text-foreground hover:bg-muted/80")}>
                  <Icon className="h-4 w-4 shrink-0"/>
                  {item.label}
                </Link>
              </TooltipTrigger>
              <TooltipContent side="right" className="max-w-xs">
                {item.hint}
              </TooltipContent>
            </Tooltip>);
        })}
      </nav>
    </aside>);
}
