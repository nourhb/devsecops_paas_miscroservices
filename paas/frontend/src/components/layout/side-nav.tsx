"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import {
  Activity,
  Box,
  FolderKanban,
  GitBranch,
  LayoutDashboard,
  PlusCircle,
  Shield
} from "lucide-react";
import { cn } from "@/lib/utils";

const primaryNav = [
  { href: "/dashboard", label: "Dashboard", icon: LayoutDashboard, prefix: "/dashboard" },
  { href: "/projects", label: "Projects", icon: FolderKanban, prefix: "/projects" },
  { href: "/projects/create", label: "New project", icon: PlusCircle, prefix: "/projects/create" }
] as const;

export function SideNav() {
  const pathname = usePathname();

  return (
    <aside className="hidden min-h-screen w-64 shrink-0 border-r border-border bg-card p-4 lg:block">
      <div className="mb-8">
        <p className="text-xs uppercase tracking-widest text-muted">DevSecOps PaaS</p>
        <h1 className="text-2xl font-semibold">Control Plane</h1>
      </div>
      <nav className="space-y-2">
        {primaryNav.map((item) => {
          const Icon = item.icon;
          const active =
            item.prefix === "/projects"
              ? pathname.startsWith("/projects") && pathname !== "/projects/create"
              : pathname === item.href || pathname.startsWith(item.prefix + "/");
          return (
            <Link
              key={item.href}
              href={item.href}
              className={cn(
                "flex items-center gap-3 rounded-md px-3 py-2 text-sm transition-colors",
                active ? "bg-primary text-background" : "text-foreground hover:bg-muted/80"
              )}
            >
              <Icon className="h-4 w-4 shrink-0" />
              {item.label}
            </Link>
          );
        })}
      </nav>
      <p className="mt-8 mb-2 text-xs font-medium uppercase tracking-wider text-muted">Per project</p>
      <p className="text-xs text-muted">
        Open a project from <span className="text-foreground">Projects</span> to access pipeline, Docker, security, and
        monitoring for that repository.
      </p>
      <div className="mt-4 space-y-1 text-xs text-muted">
        <div className="flex items-center gap-2">
          <GitBranch className="h-3.5 w-3.5" />
          <span>CI/CD &amp; Argo CD</span>
        </div>
        <div className="flex items-center gap-2">
          <Box className="h-3.5 w-3.5" />
          <span>Container registry</span>
        </div>
        <div className="flex items-center gap-2">
          <Shield className="h-3.5 w-3.5" />
          <span>Trivy &amp; gates</span>
        </div>
        <div className="flex items-center gap-2">
          <Activity className="h-3.5 w-3.5" />
          <span>Prometheus / Grafana</span>
        </div>
      </div>
    </aside>
  );
}
