"use client";

import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { Activity, FolderKanban, Loader2, Percent, Plus, Rocket } from "lucide-react";
import { OverviewStatCard } from "@/components/dashboard/overview-stat-card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { dashboardOverviewApi } from "@/lib/api";
import { cn } from "@/lib/utils";

function deploymentStatusBadgeVariant(
  status: string
): "success" | "danger" | "warning" | "outline" {
  const s = status.toUpperCase();
  if (s === "SUCCESS" || s === "DEPLOYED") return "success";
  if (s === "FAILED") return "danger";
  if (s === "PENDING" || s === "DEPLOYING") return "warning";
  return "outline";
}

function formatRelativeTime(iso: string): string {
  const d = new Date(iso);
  const diffMs = Date.now() - d.getTime();
  const sec = Math.floor(diffMs / 1000);
  if (sec < 45) return "Just now";
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const days = Math.floor(hr / 24);
  if (days < 7) return `${days}d ago`;
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

function StatsSkeleton() {
  return (
    <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
      {Array.from({ length: 4 }).map((_, i) => (
        <Card key={i} className="rounded-xl border-border/70 shadow-sm">
          <div className="p-5">
            <Skeleton className="h-3 w-24" />
            <Skeleton className="mt-3 h-9 w-16" />
          </div>
        </Card>
      ))}
    </div>
  );
}

export default function DashboardPage() {
  const overviewQuery = useQuery({
    queryKey: ["dashboard-overview"],
    queryFn: dashboardOverviewApi.get,
    refetchInterval: 20_000
  });

  const stats = overviewQuery.data?.stats;
  const recent = overviewQuery.data?.recentDeployments ?? [];

  const successDisplay =
    stats?.successRatePercent === null || stats?.successRatePercent === undefined
      ? "—"
      : `${stats.successRatePercent}%`;

  return (
    <div className="mx-auto max-w-6xl space-y-10">
      <header className="flex flex-col gap-6 border-b border-border/60 pb-8 sm:flex-row sm:items-end sm:justify-between">
        <div className="space-y-1">
          <p className="text-xs font-medium text-muted">Overview</p>
          <h1 className="text-2xl font-semibold tracking-tight text-foreground sm:text-3xl">Dashboard</h1>
          <p className="max-w-lg text-sm text-muted">
            Projects and deployments you can access. Stats refresh automatically.
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button variant="outline" size="sm" className="shadow-sm" asChild>
            <Link href="/projects">View projects</Link>
          </Button>
          <Button size="sm" className="shadow-sm" asChild>
            <Link href="/projects/create">
              <Plus className="mr-2 h-4 w-4" />
              New project
            </Link>
          </Button>
        </div>
      </header>

      {overviewQuery.isError ? (
        <Card className="rounded-xl border-danger/30 bg-danger/5 shadow-sm">
          <CardHeader className="pb-2">
            <CardTitle className="text-base font-medium">Could not load dashboard</CardTitle>
            <CardDescription>Check your session and try again.</CardDescription>
          </CardHeader>
        </Card>
      ) : null}

      {overviewQuery.isLoading && !overviewQuery.data ? (
        <StatsSkeleton />
      ) : (
        <section className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <OverviewStatCard title="Total projects" value={stats?.totalProjects ?? 0} icon={FolderKanban} />
          <OverviewStatCard title="Total deployments" value={stats?.totalDeployments ?? 0} icon={Rocket} />
          <OverviewStatCard title="Success rate" value={successDisplay} icon={Percent} />
          <OverviewStatCard title="Active deployments" value={stats?.activeDeployments ?? 0} icon={Activity} />
        </section>
      )}

      <section>
        <Card className="rounded-xl border-border/70 shadow-sm">
          <CardHeader className="flex flex-row items-start justify-between space-y-0 pb-4">
            <div className="space-y-1">
              <CardTitle className="text-base font-semibold">Recent deployments</CardTitle>
              <CardDescription>Latest activity across your projects</CardDescription>
            </div>
            {overviewQuery.isFetching && overviewQuery.data ? (
              <Loader2 className="h-4 w-4 animate-spin text-muted" aria-label="Refreshing" />
            ) : null}
          </CardHeader>
          <CardContent className="px-0 pb-0">
            {overviewQuery.isLoading && !overviewQuery.data ? (
              <div className="space-y-2 px-6 pb-6">
                <Skeleton className="h-10 w-full" />
                <Skeleton className="h-10 w-full" />
                <Skeleton className="h-10 w-full" />
              </div>
            ) : recent.length === 0 ? (
              <p className="px-6 pb-8 pt-2 text-center text-sm text-muted">
                No deployments yet. Open a project and run a deploy to see it here.
              </p>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow className="border-border/60 hover:bg-transparent">
                    <TableHead className="pl-6 text-xs font-medium uppercase tracking-wider text-muted">
                      Project
                    </TableHead>
                    <TableHead className="text-xs font-medium uppercase tracking-wider text-muted">Status</TableHead>
                    <TableHead className="pr-6 text-right text-xs font-medium uppercase tracking-wider text-muted">
                      Time
                    </TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {recent.map((row) => (
                    <TableRow
                      key={row.id}
                      className={cn("border-border/50 transition-colors hover:bg-muted/30")}
                    >
                      <TableCell className="pl-6 font-medium">
                        <Link
                          href={`/deployments/${row.id}`}
                          className="text-foreground hover:text-primary hover:underline underline-offset-4"
                        >
                          {row.projectName}
                        </Link>
                      </TableCell>
                      <TableCell>
                        <Badge variant={deploymentStatusBadgeVariant(row.status)}>{row.status}</Badge>
                      </TableCell>
                      <TableCell className="pr-6 text-right text-sm tabular-nums text-muted">
                        <span title={new Date(row.createdAt).toLocaleString()}>{formatRelativeTime(row.createdAt)}</span>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </CardContent>
        </Card>
      </section>
    </div>
  );
}
