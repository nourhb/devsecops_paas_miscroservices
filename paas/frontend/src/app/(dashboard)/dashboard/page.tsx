"use client";
import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { Activity, AlertTriangle, Boxes, ExternalLink, FolderKanban, GitBranch, LayoutGrid, Loader2, Package, Percent, Plus, Rocket, Shield, ServerCog } from "lucide-react";
import { Bar, BarChart, CartesianGrid, Cell, Legend, Pie, PieChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { OverviewStatCard } from "@/components/dashboard/overview-stat-card";
import { DashboardPodsPanel } from "@/components/dashboard/dashboard-pods-panel";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { dashboardOverviewApi } from "@/lib/api";
import { cn } from "@/lib/utils";
const chartColors = {
    success: "#22c55e",
    warning: "#f59e0b",
    danger: "#ef4444",
    info: "#06b6d4",
    muted: "#64748b"
};
function deploymentStatusBadgeVariant(status: string): "success" | "danger" | "warning" | "outline" {
    const s = status.toUpperCase();
    if (s === "SUCCESS" || s === "DEPLOYED")
        return "success";
    if (s === "FAILED")
        return "danger";
    if (s === "PENDING" || s === "DEPLOYING")
        return "warning";
    return "outline";
}
function statusVariant(status: string | null | undefined): "success" | "danger" | "warning" | "outline" {
    const s = String(status ?? "").toUpperCase();
    if (["SUCCESS", "DEPLOYED", "RUNNING", "HEALTHY", "PASSED", "LIVE"].includes(s)) {
        return "success";
    }
    if (s.includes("FAIL") || s.includes("ERROR") || s.includes("DENIED") || s.includes("BLOCK")) {
        return "danger";
    }
    if (s.includes("PENDING") || s.includes("DEPLOYING") || s.includes("UNKNOWN") || s.includes("DEGRADED")) {
        return "warning";
    }
    return "outline";
}
function formatRelativeTime(iso: string): string {
    const d = new Date(iso);
    const diffMs = Date.now() - d.getTime();
    const sec = Math.floor(diffMs / 1000);
    if (sec < 45)
        return "Just now";
    const min = Math.floor(sec / 60);
    if (min < 60)
        return `${min}m ago`;
    const hr = Math.floor(min / 60);
    if (hr < 24)
        return `${hr}h ago`;
    const days = Math.floor(hr / 24);
    if (days < 7)
        return `${days}d ago`;
    return d.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}
function StatsSkeleton() {
    return (<div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
      {Array.from({ length: 4 }).map((_, i) => (<Card key={i} className="rounded-xl border-border/70 shadow-sm">
          <div className="p-5">
            <Skeleton className="h-3 w-24"/>
            <Skeleton className="mt-3 h-9 w-16"/>
          </div>
        </Card>))}
    </div>);
}
function ChartEmptyState({ title, children }: {
    title: string;
    children: React.ReactNode;
}) {
    return (<div className="flex h-[220px] flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-border/70 px-6 text-center">
      <p className="text-sm font-medium text-foreground">{title}</p>
      <div className="max-w-md text-sm leading-relaxed text-muted">{children}</div>
    </div>);
}
export default function DashboardPage() {
    const overviewQuery = useQuery({
        queryKey: ["dashboard-overview"],
        queryFn: dashboardOverviewApi.get,
        refetchInterval: 20000
    });
    const stats = overviewQuery.data?.stats;
    const recent = overviewQuery.data?.recentDeployments ?? [];
    const cluster = overviewQuery.data?.cluster;
    const security = overviewQuery.data?.security;
    const tools = overviewQuery.data?.platformTools ?? [];
    const projects = overviewQuery.data?.projects ?? [];
    const failures = overviewQuery.data?.failedDeployments ?? [];
    const artifacts = overviewQuery.data?.artifacts ?? [];
    const clusterDataSource = overviewQuery.data?.clusterDataSource ?? "none";
    const successDisplay = stats?.successRatePercent === null || stats?.successRatePercent === undefined
        ? "\u2014"
        : `${stats.successRatePercent}%`;
    const successfulDeployments = Math.max(0, (stats?.totalDeployments ?? 0) - (stats?.activeDeployments ?? 0) - (stats?.failedDeployments ?? 0));
    const workloadChartData = [
        { name: "Pods", value: cluster?.pods ?? 0, fill: chartColors.info },
        { name: "Running", value: cluster?.runningPods ?? 0, fill: chartColors.success },
        { name: "Services", value: cluster?.services ?? 0, fill: chartColors.warning },
        { name: "Deployments", value: cluster?.deployments ?? 0, fill: chartColors.muted }
    ];
    const deliveryChartData = [
        { name: "Successful", value: successfulDeployments, fill: chartColors.success, dotClassName: "bg-success" },
        { name: "Active", value: stats?.activeDeployments ?? 0, fill: chartColors.warning, dotClassName: "bg-warning" },
        { name: "Failed", value: stats?.failedDeployments ?? 0, fill: chartColors.danger, dotClassName: "bg-danger" }
    ].filter((item) => item.value > 0);
    const securityChartData = [
        { name: "Critical", value: security?.critical ?? 0, fill: chartColors.danger },
        { name: "High", value: security?.high ?? 0, fill: chartColors.warning },
        { name: "Medium", value: security?.medium ?? 0, fill: "#eab308" },
        { name: "Low", value: security?.low ?? 0, fill: chartColors.success },
        { name: "Unsigned", value: security?.unsignedImages ?? 0, fill: chartColors.info },
        { name: "Not allowed", value: security?.policyBlocked ?? 0, fill: chartColors.muted }
    ];
    const scanCompareData = [
        { severity: "Critical", dt: security?.dependencyTrack.critical ?? 0, trivy: security?.trivy.critical ?? 0 },
        { severity: "High", dt: security?.dependencyTrack.high ?? 0, trivy: security?.trivy.high ?? 0 },
        { severity: "Medium", dt: security?.dependencyTrack.medium ?? 0, trivy: security?.trivy.medium ?? 0 },
        { severity: "Low", dt: security?.dependencyTrack.low ?? 0, trivy: security?.trivy.low ?? 0 }
    ];
    const sonarPassed = security?.sonar.passed ?? 0;
    const sonarFailed = security?.sonar.failed ?? 0;
    const sonarUnknown = security?.sonar.unknown ?? 0;
    const sonarGateData = [
        { name: "Passed", value: sonarPassed, fill: chartColors.success },
        { name: "Failed", value: sonarFailed, fill: chartColors.danger },
        { name: "Unknown", value: sonarUnknown, fill: chartColors.muted }
    ];
    const sonarGateHasSignal = sonarPassed + sonarFailed + sonarUnknown > 0;
    const policySignalData = [
        { name: "Cosign unsigned", value: security?.unsignedImages ?? 0, fill: chartColors.info },
        { name: "Deploy blocked", value: security?.policyBlocked ?? 0, fill: chartColors.danger },
        { name: "Kyverno gap", value: security?.kyverno.projectsWithPolicyGap ?? 0, fill: "#a855f7" },
        { name: "OPA policy gap", value: security?.opa.projectsWithPolicyGap ?? 0, fill: "#6366f1" },
        { name: "OPA violations", value: security?.opa.violationCount ?? 0, fill: chartColors.warning }
    ];
    const toolHealthChartData = [
        { name: "Live", value: stats?.liveTools ?? 0, fill: chartColors.success, dotClassName: "bg-success" },
        { name: "Degraded", value: stats?.degradedTools ?? 0, fill: chartColors.warning, dotClassName: "bg-warning" },
        {
            name: "Other",
            value: Math.max(0, tools.flatMap((group) => group.items).length - (stats?.liveTools ?? 0) - (stats?.degradedTools ?? 0)),
            fill: chartColors.muted,
            dotClassName: "bg-slate-500"
        }
    ].filter((item) => item.value > 0);
    return (<div className="mx-auto max-w-7xl space-y-8">
      <header className="flex flex-col gap-6 border-b border-border/60 pb-8 sm:flex-row sm:items-end sm:justify-between">
        <div className="space-y-1">
          <p className="text-xs font-medium text-muted">Overview</p>
          <h1 className="text-2xl font-semibold tracking-tight text-foreground sm:text-3xl">DevSecOps command center</h1>
          <p className="max-w-2xl text-sm leading-relaxed text-muted">
            A single, guided experience for build, deploy, and cluster visibility. Security is layered in over time: static analysis (SAST),
            vulnerability and SBOM workflows, signed images, and policy on Kubernetes—each appears here and in CI as you connect tools.
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button variant="outline" size="sm" className="shadow-sm" asChild>
            <Link href="/integrations">
              <LayoutGrid className="mr-2 h-4 w-4"/>
              Platform hub
            </Link>
          </Button>
          <Button variant="outline" size="sm" className="shadow-sm" asChild>
            <Link href="/projects">View projects</Link>
          </Button>
          <Button size="sm" className="shadow-sm" asChild>
            <Link href="/projects/create">
              <Plus className="mr-2 h-4 w-4"/>
              New project
            </Link>
          </Button>
        </div>
      </header>

      <Card className="rounded-xl border-primary/20 bg-primary/5 shadow-sm">
        <CardHeader className="pb-2">
          <CardTitle className="text-base font-semibold text-foreground">Unified delivery and DevSecOps</CardTitle>
          <CardDescription className="text-sm text-muted">
            Jenkins/Tekton builds, GitOps handoff, and Argo CD sync stay in one workflow. Gates you can turn on gradually: Sonar (SAST), Dependency-Track and SBOM,
            Trivy and SCA archives, Cosign signatures, and Kyverno, Gatekeeper, or Kubewarden policy on the cluster.
          </CardDescription>
        </CardHeader>
      </Card>

      {overviewQuery.isError ? (<Card className="rounded-xl border-danger/30 bg-danger/5 shadow-sm">
          <CardHeader className="pb-2">
            <CardTitle className="text-base font-medium">Could not load dashboard</CardTitle>
            <CardDescription>Check your session and try again.</CardDescription>
          </CardHeader>
        </Card>) : null}

      {overviewQuery.isLoading && !overviewQuery.data ? (<StatsSkeleton />) : (<section className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <OverviewStatCard title="Total projects" value={stats?.totalProjects ?? 0} icon={FolderKanban}/>
          <OverviewStatCard title={clusterDataSource === "project_rollups" ? "Healthy workloads" : "Running pods"} value={`${stats?.runningPods ?? 0}/${cluster?.pods ?? 0}`} icon={ServerCog}/>
          <OverviewStatCard title="Security score" value={`${security?.score ?? 0}/100`} icon={Shield}/>
          <OverviewStatCard title="Live tools" value={`${stats?.liveTools ?? 0}`} icon={Activity}/>
        </section>)}

      <section className="grid gap-4 xl:grid-cols-2">
        <Card className="rounded-xl border-border/70 shadow-sm">
          <CardHeader className="pb-3">
            <CardTitle className="text-base">Cluster workload</CardTitle>
            <CardDescription>
              {clusterDataSource === "kubernetes" && "Pods, services, and deployments from Kubernetes."}
              {clusterDataSource === "project_rollups" && "Rollups from your projects and deployment history (Kubernetes API not in use)."}
              {clusterDataSource === "none" && "Connect Kubernetes or add projects to see workload signals."}
            </CardDescription>
          </CardHeader>
          <CardContent>
            {workloadChartData.every((item) => item.value === 0) ? (<ChartEmptyState title="Nothing to plot yet">
                {clusterDataSource === "kubernetes"
                ? "Kubernetes returned zero pods, services, and deployments for your filters, or the cluster is empty."
                : clusterDataSource === "project_rollups"
                    ? "Project rollups are all zero \u2014 add projects and run deploys so workload counts update, or connect Kubernetes for live cluster metrics."
                    : "Add projects or connect Kubernetes; there is no data to chart for workload right now."}
              </ChartEmptyState>) : (<div className="h-[240px]">
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={workloadChartData} margin={{ left: -20, right: 12, top: 8 }}>
                  <CartesianGrid strokeDasharray="3 3" stroke="hsl(var(--border))" vertical={false}/>
                  <XAxis dataKey="name" tickLine={false} axisLine={false} tick={{ fill: "hsl(var(--muted-foreground))", fontSize: 12 }}/>
                  <YAxis allowDecimals={false} tickLine={false} axisLine={false} tick={{ fill: "hsl(var(--muted-foreground))", fontSize: 12 }}/>
                  <Tooltip cursor={{ fill: "hsl(var(--muted) / 0.25)" }} contentStyle={{ background: "hsl(var(--card))", border: "1px solid hsl(var(--border))", borderRadius: 12 }}/>
                  <Bar dataKey="value" radius={[8, 8, 0, 0]}>
                    {workloadChartData.map((entry) => <Cell key={entry.name} fill={entry.fill}/>)}
                  </Bar>
                </BarChart>
              </ResponsiveContainer>
            </div>)}
          </CardContent>
        </Card>

        <Card className="rounded-xl border-border/70 shadow-sm">
          <CardHeader className="pb-3">
            <CardTitle className="text-base">Delivery outcome</CardTitle>
            <CardDescription>Success, active, and failed deployment history.</CardDescription>
          </CardHeader>
          <CardContent className="grid gap-4 sm:grid-cols-[1fr_160px]">
            {deliveryChartData.length === 0 ? (<ChartEmptyState title="No segments for this pie">
                {(stats?.totalDeployments ?? 0) === 0
                ? "There are no deployment rows yet. Trigger a build/deploy from a project; finished jobs will appear here as successful, active, or failed."
                : "All current jobs are still in categories with zero count (for example only pending). Open the project board below or Deployments for live status."}
              </ChartEmptyState>) : (<div className="h-[220px]">
              <ResponsiveContainer width="100%" height="100%">
                <PieChart>
                  <Pie data={deliveryChartData} dataKey="value" nameKey="name" innerRadius={58} outerRadius={90} paddingAngle={3}>
                    {deliveryChartData.map((entry) => <Cell key={entry.name} fill={entry.fill}/>)}
                  </Pie>
                  <Tooltip contentStyle={{ background: "hsl(var(--card))", border: "1px solid hsl(var(--border))", borderRadius: 12 }}/>
                </PieChart>
              </ResponsiveContainer>
            </div>)}
            <div className="grid content-center gap-2">
              {deliveryChartData.map((item) => (<div key={item.name} className="flex items-center justify-between rounded-lg border border-border/70 px-3 py-2 text-sm">
                <span className="flex items-center gap-2"><span className={cn("h-2.5 w-2.5 rounded-full", item.dotClassName)}/>{item.name}</span>
                <span className="font-semibold">{item.value}</span>
              </div>))}
      </div>
          </CardContent>
        </Card>

        <Card className="rounded-xl border-border/70 shadow-sm xl:col-span-2">
          <CardHeader className="pb-3">
            <CardTitle className="text-base">Security posture (live tool data)</CardTitle>
            <CardDescription>
              Rolled up from the same SonarQube, Dependency-Track, Trivy, Cosign, OPA, and Kyverno calls as the project Security page, across up to {security?.sampledProjects ?? 0} recent projects.
            </CardDescription>
          </CardHeader>
          <CardContent className="grid gap-6 lg:grid-cols-2">
            <div>
              <p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted">All findings (SCA + image scan)</p>
              {securityChartData.every((item) => item.value === 0) ? (<ChartEmptyState title="No counted findings yet">
                  Zeros usually mean scanners are not configured, returned no vulnerabilities for the sampled image refs, or projects lack image tags. Configure tool URLs under Integrations / env and open a project Security tab to verify per-project responses.
                </ChartEmptyState>) : (<div className="h-[260px]">
                <ResponsiveContainer width="100%" height="100%">
                  <BarChart data={securityChartData} layout="vertical" margin={{ left: 8, right: 16, top: 8, bottom: 8 }}>
                    <CartesianGrid strokeDasharray="3 3" stroke="hsl(var(--border))" horizontal={false}/>
                    <XAxis type="number" allowDecimals={false} tickLine={false} axisLine={false} tick={{ fill: "hsl(var(--muted-foreground))", fontSize: 12 }}/>
                    <YAxis type="category" dataKey="name" width={88} tickLine={false} axisLine={false} tick={{ fill: "hsl(var(--muted-foreground))", fontSize: 11 }}/>
                    <Tooltip cursor={{ fill: "hsl(var(--muted) / 0.25)" }} contentStyle={{ background: "hsl(var(--card))", border: "1px solid hsl(var(--border))", borderRadius: 12 }}/>
                    <Bar dataKey="value" radius={[0, 8, 8, 0]}>
                      {securityChartData.map((entry) => <Cell key={entry.name} fill={entry.fill}/>)}
                    </Bar>
                  </BarChart>
                </ResponsiveContainer>
              </div>)}
            </div>
            <div>
              <p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted">Dependency-Track vs Trivy by severity</p>
              <div className="h-[260px]">
                <ResponsiveContainer width="100%" height="100%">
                  <BarChart data={scanCompareData} margin={{ left: 4, right: 8, top: 8, bottom: 4 }}>
                    <CartesianGrid strokeDasharray="3 3" stroke="hsl(var(--border))" vertical={false}/>
                    <XAxis dataKey="severity" tickLine={false} axisLine={false} tick={{ fill: "hsl(var(--muted-foreground))", fontSize: 11 }}/>
                    <YAxis allowDecimals={false} tickLine={false} axisLine={false} tick={{ fill: "hsl(var(--muted-foreground))", fontSize: 11 }}/>
                    <Tooltip contentStyle={{ background: "hsl(var(--card))", border: "1px solid hsl(var(--border))", borderRadius: 12 }}/>
                    <Legend wrapperStyle={{ fontSize: 12 }}/>
                    <Bar dataKey="dt" name="Dependency-Track" fill="#0ea5e9" radius={[6, 6, 0, 0]}/>
                    <Bar dataKey="trivy" name="Trivy" fill="#f97316" radius={[6, 6, 0, 0]}/>
                  </BarChart>
                </ResponsiveContainer>
              </div>
            </div>
            <div>
              <p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted">SonarQube quality gate (projects sampled)</p>
              {(!sonarGateHasSignal || (security?.sampledProjects ?? 0) === 0) ? (<ChartEmptyState title="No Sonar gate results">
                  With tools configured, each sampled project reports PASSED, FAILED, or UNKNOWN. UNKNOWN usually means Sonar is not configured or the project key did not match.
                </ChartEmptyState>) : (<div className="h-[220px]">
                <ResponsiveContainer width="100%" height="100%">
                  <PieChart>
                    <Pie data={sonarGateData} dataKey="value" nameKey="name" innerRadius={48} outerRadius={80} paddingAngle={2}>
                      {sonarGateData.map((entry) => <Cell key={entry.name} fill={entry.fill}/>)}
                    </Pie>
                    <Tooltip contentStyle={{ background: "hsl(var(--card))", border: "1px solid hsl(var(--border))", borderRadius: 12 }}/>
                    <Legend wrapperStyle={{ fontSize: 12 }}/>
                  </PieChart>
                </ResponsiveContainer>
              </div>)}
            </div>
            <div>
              <p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted">Signing & policy (Cosign / OPA / Kyverno)</p>
              <div className="h-[220px]">
                <ResponsiveContainer width="100%" height="100%">
                  <BarChart data={policySignalData} layout="vertical" margin={{ left: 8, right: 16, top: 8, bottom: 8 }}>
                    <CartesianGrid strokeDasharray="3 3" stroke="hsl(var(--border))" horizontal={false}/>
                    <XAxis type="number" allowDecimals={false} tickLine={false} axisLine={false} tick={{ fill: "hsl(var(--muted-foreground))", fontSize: 12 }}/>
                    <YAxis type="category" dataKey="name" width={120} tickLine={false} axisLine={false} tick={{ fill: "hsl(var(--muted-foreground))", fontSize: 11 }}/>
                    <Tooltip contentStyle={{ background: "hsl(var(--card))", border: "1px solid hsl(var(--border))", borderRadius: 12 }}/>
                    <Bar dataKey="value" radius={[0, 8, 8, 0]}>
                      {policySignalData.map((entry) => <Cell key={entry.name} fill={entry.fill}/>)}
                    </Bar>
                  </BarChart>
                </ResponsiveContainer>
              </div>
            </div>
          </CardContent>
        </Card>

        <Card className="rounded-xl border-border/70 shadow-sm">
          <CardHeader className="pb-3">
            <CardTitle className="text-base">Tool health</CardTitle>
            <CardDescription>Live and degraded platform tools from configured integrations.</CardDescription>
          </CardHeader>
          <CardContent className="grid gap-4 sm:grid-cols-[1fr_160px]">
            {toolHealthChartData.length === 0 ? (<ChartEmptyState title="No tool health segments">
                Platform tooling has not returned live vs degraded counts yet. Open the Platform hub to run reachability checks, or wait for the background poll to finish.
              </ChartEmptyState>) : (<div className="h-[220px]">
              <ResponsiveContainer width="100%" height="100%">
                <PieChart>
                  <Pie data={toolHealthChartData} dataKey="value" nameKey="name" innerRadius={54} outerRadius={88} paddingAngle={3}>
                    {toolHealthChartData.map((entry) => <Cell key={entry.name} fill={entry.fill}/>)}
                  </Pie>
                  <Tooltip contentStyle={{ background: "hsl(var(--card))", border: "1px solid hsl(var(--border))", borderRadius: 12 }}/>
                </PieChart>
              </ResponsiveContainer>
            </div>)}
            <div className="grid content-center gap-2">
              {toolHealthChartData.map((item) => (<div key={item.name} className="flex items-center justify-between rounded-lg border border-border/70 px-3 py-2 text-sm">
                <span className="flex items-center gap-2"><span className={cn("h-2.5 w-2.5 rounded-full", item.dotClassName)}/>{item.name}</span>
                <span className="font-semibold">{item.value}</span>
              </div>))}
            </div>
          </CardContent>
        </Card>
      </section>

      <DashboardPodsPanel fallbackProjects={projects} overviewLoading={overviewQuery.isLoading && !overviewQuery.data} clusterDataSource={clusterDataSource}/>

      <section className="grid gap-4 lg:grid-cols-3">
        <Card className="rounded-xl border-border/70 shadow-sm lg:col-span-2">
          <CardHeader className="pb-3">
            <CardTitle className="text-base">Platform health</CardTitle>
            <CardDescription>Live signals collected through this app, not VM access.</CardDescription>
          </CardHeader>
          <CardContent className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            <div className="rounded-lg border border-border/70 bg-muted/10 p-3">
              <p className="text-xs font-medium uppercase tracking-wide text-muted">Cluster</p>
              <p className="mt-2 text-2xl font-semibold">{cluster?.healthyDeployments ?? 0}/{cluster?.deployments ?? 0}</p>
              <p className="text-xs text-muted">
                {clusterDataSource === "project_rollups" ? `${cluster?.services ?? 0} projects with a public URL` : `${cluster?.services ?? 0} services`}
              </p>
            </div>
            <div className="rounded-lg border border-border/70 bg-muted/10 p-3">
              <p className="text-xs font-medium uppercase tracking-wide text-muted">Security</p>
              <p className="mt-2 text-2xl font-semibold">{security?.critical ?? 0} critical</p>
              <p className="text-xs text-muted">
                {security?.high ?? 0} high · Sonar fail {security?.sonar.failed ?? 0} · {security?.unsignedImages ?? 0} unsigned · Kyverno gaps {security?.kyverno.projectsWithPolicyGap ?? 0}
              </p>
            </div>
            <div className="rounded-lg border border-border/70 bg-muted/10 p-3">
              <p className="text-xs font-medium uppercase tracking-wide text-muted">Delivery</p>
              <p className="mt-2 text-2xl font-semibold">{successDisplay}</p>
              <p className="text-xs text-muted">{stats?.activeDeployments ?? 0} active · {stats?.failedDeployments ?? 0} failed</p>
            </div>
          </CardContent>
        </Card>

        <Card className="rounded-xl border-border/70 shadow-sm">
          <CardHeader className="pb-3">
            <CardTitle className="text-base">Quick actions</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-2">
            <Button asChild variant="outline" className="justify-start">
              <Link href="/cluster"><ServerCog className="mr-2 h-4 w-4"/>Cluster data</Link>
            </Button>
            <Button asChild variant="outline" className="justify-start">
              <Link href="/integrations"><LayoutGrid className="mr-2 h-4 w-4"/>Tool health map</Link>
            </Button>
            <Button asChild variant="outline" className="justify-start">
              <Link href="/artifacts"><Package className="mr-2 h-4 w-4"/>Image artifacts</Link>
            </Button>
          </CardContent>
        </Card>
      </section>

      <section className="grid gap-4 xl:grid-cols-[1.2fr_0.8fr]">
        <Card className="rounded-xl border-border/70 shadow-sm">
          <CardHeader className="flex flex-row items-start justify-between space-y-0 pb-4">
            <div>
              <CardTitle className="text-base">Project command board</CardTitle>
              <CardDescription>Build, deploy, pod and artifact state per project.</CardDescription>
            </div>
            {overviewQuery.isFetching && overviewQuery.data ? (<Loader2 className="h-4 w-4 animate-spin text-muted" aria-label="Refreshing"/>) : null}
          </CardHeader>
          <CardContent className="px-0 pb-0">
            {projects.length === 0 ? (<p className="px-6 pb-6 text-sm text-muted">No projects yet.</p>) : (<Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="pl-6">Project</TableHead>
                  <TableHead>Build</TableHead>
                  <TableHead>Deploy</TableHead>
                  <TableHead>Pod</TableHead>
                  <TableHead>Artifact</TableHead>
                  <TableHead className="pr-6 text-right">Open</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {projects.map((project) => (<TableRow key={project.id}>
                  <TableCell className="pl-6 font-medium">
                    <Link href={`/projects/${project.id}`} className="hover:text-primary hover:underline">{project.projectName}</Link>
                  </TableCell>
                  <TableCell><Badge variant={statusVariant(project.buildStatus)}>{project.buildStatus}</Badge></TableCell>
                  <TableCell><Badge variant={statusVariant(project.lastDeploymentStatus)}>{project.lastDeploymentStatus}</Badge></TableCell>
                  <TableCell><Badge variant={statusVariant(project.podStatus)}>{project.podStatus}</Badge></TableCell>
                  <TableCell className="max-w-[220px] truncate font-mono text-xs">{project.imageTag || "\u2014"}</TableCell>
                  <TableCell className="pr-6 text-right">
                    <Button asChild variant="outline" size="sm">
                      <Link href={`/projects/${project.id}`}>Manage</Link>
                    </Button>
                  </TableCell>
                </TableRow>))}
              </TableBody>
            </Table>)}
          </CardContent>
        </Card>

        <Card className="rounded-xl border-border/70 shadow-sm">
          <CardHeader className="pb-3">
            <CardTitle className="flex items-center gap-2 text-base">
              <AlertTriangle className="h-4 w-4 text-warning"/>
              Latest failures
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            {failures.length === 0 ? (<p className="text-sm text-muted">No failed deployments in the latest history.</p>) : failures.map((failure) => (<Link key={failure.id} href={`/deployments/${failure.id}`} className="block rounded-lg border border-border/70 p-3 hover:bg-muted/30">
              <div className="flex items-center justify-between gap-3">
                <p className="font-medium">{failure.projectName}</p>
                <Badge variant="danger">{failure.status}</Badge>
              </div>
              <p className="mt-1 line-clamp-2 text-xs text-muted">{failure.failureMessage || failure.failureReason || "Open logs for details."}</p>
              <p className="mt-2 text-xs text-muted">{formatRelativeTime(failure.createdAt)}</p>
            </Link>))}
          </CardContent>
        </Card>
      </section>

      <section className="grid gap-4 xl:grid-cols-2">
        <Card className="rounded-xl border-border/70 shadow-sm">
          <CardHeader>
            <CardTitle className="text-base">Platform tool signals</CardTitle>
            <CardDescription>Kubernetes-backed status for the tools replacing VM visits.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            {tools.slice(0, 4).map((group) => (<div key={group.title}>
              <div className="mb-2 flex items-center gap-2">
                <p className="text-sm font-medium">{group.title}</p>
                <Badge variant="outline">{group.items.filter((item) => item.tone === "success").length}/{group.items.length} live</Badge>
              </div>
              <div className="grid gap-2 sm:grid-cols-2">
                {group.items.slice(0, 4).map((item) => (<div key={`${group.title}-${item.name}`} className="rounded-lg border border-border/70 p-2">
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-sm">{item.name}</span>
                    <Badge variant={item.tone} className="text-xs">{item.tone}</Badge>
                  </div>
                  <p className="mt-1 line-clamp-2 text-xs text-muted">{item.detail}</p>
                </div>))}
              </div>
            </div>))}
          </CardContent>
        </Card>

        <Card className="rounded-xl border-border/70 shadow-sm">
          <CardHeader>
            <CardTitle className="text-base">Latest image artifacts</CardTitle>
            <CardDescription>Images and build outputs tracked by the platform.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-2">
            {artifacts.length === 0 ? (<p className="text-sm text-muted">No image artifacts recorded yet.</p>) : artifacts.map((artifact) => (<div key={artifact.path} className="flex items-center justify-between gap-3 rounded-lg border border-border/70 p-3">
              <div className="min-w-0">
                <p className="truncate font-medium">{artifact.name}:{artifact.version}</p>
                <p className="truncate text-xs text-muted">{artifact.path}</p>
              </div>
              {artifact.downloadUrl ? (<Button asChild variant="outline" size="sm">
                <a href={artifact.downloadUrl} target="_blank" rel="noreferrer">
                  <ExternalLink className="mr-2 h-4 w-4"/>
                  Open
                </a>
              </Button>) : null}
            </div>))}
          </CardContent>
        </Card>
      </section>

      <section>
        <Card className="rounded-xl border-border/70 shadow-sm">
          <CardHeader className="flex flex-row items-start justify-between space-y-0 pb-4">
            <div className="space-y-1">
              <CardTitle className="text-base font-semibold">Recent deployments</CardTitle>
              <CardDescription>Latest activity across your projects</CardDescription>
    </div>
            {overviewQuery.isFetching && overviewQuery.data ? (<Loader2 className="h-4 w-4 animate-spin text-muted" aria-label="Refreshing"/>) : null}
          </CardHeader>
          <CardContent className="px-0 pb-0">
            {overviewQuery.isLoading && !overviewQuery.data ? (<div className="space-y-2 px-6 pb-6">
                <Skeleton className="h-10 w-full"/>
                <Skeleton className="h-10 w-full"/>
                <Skeleton className="h-10 w-full"/>
              </div>) : recent.length === 0 ? (<p className="px-6 pb-8 pt-2 text-center text-sm text-muted">
                No deployments yet. Open a project and run a deploy to see it here.
              </p>) : (<Table>
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
                  {recent.map((row) => (<TableRow key={row.id} className={cn("border-border/50 transition-colors hover:bg-muted/30")}>
                      <TableCell className="pl-6 font-medium">
                        <Link href={`/deployments/${row.id}`} className="text-foreground hover:text-primary hover:underline underline-offset-4">
                          {row.projectName}
                        </Link>
                      </TableCell>
                      <TableCell>
                        <Badge variant={deploymentStatusBadgeVariant(row.status)}>{row.status}</Badge>
                      </TableCell>
                      <TableCell className="pr-6 text-right text-sm tabular-nums text-muted">
                        <span title={new Date(row.createdAt).toLocaleString()}>{formatRelativeTime(row.createdAt)}</span>
                      </TableCell>
                    </TableRow>))}
                </TableBody>
              </Table>)}
          </CardContent>
        </Card>
      </section>
    </div>);
}
