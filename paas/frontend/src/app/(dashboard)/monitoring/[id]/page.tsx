"use client";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Activity, AlertCircle, Boxes, ChevronRight, ExternalLink, FileText, Loader2, RefreshCcw, Server } from "lucide-react";
import { Bar, BarChart, CartesianGrid, Cell, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Textarea } from "@/components/ui/textarea";
import { argocdApi, kubernetesApi, monitoringApi, pipelineApi } from "@/lib/api";
import type { MonitoringKubernetesPod } from "@/types";
import { cn } from "@/lib/utils";
const chartCpu = "#0ea5e9";
const chartMem = "#f97316";
const phaseColors: Record<string, string> = {
    Running: "#22c55e",
    Pending: "#f59e0b",
    Failed: "#ef4444",
    Succeeded: "#64748b",
    Other: "#94a3b8"
};
function formatChartTime(ts: number) {
    return new Date(ts).toLocaleTimeString([], {
        hour: "2-digit",
        minute: "2-digit"
    });
}
function podStatusBadgeVariant(status: string): "success" | "warning" | "danger" | "outline" {
    const s = status.toLowerCase();
    if (s === "running") {
        return "success";
    }
    if (s === "pending") {
        return "warning";
    }
    if (s === "failed") {
        return "danger";
    }
    return "outline";
}
function podHealthBadgeVariant(health: string): "success" | "warning" | "danger" | "outline" {
    const h = health.toLowerCase();
    if (h === "healthy" || h === "succeeded") {
        return "success";
    }
    if (/(crashloop|imagepull|errimagepull|failed)/.test(h)) {
        return "danger";
    }
    if (/(pending|notready|terminating)/.test(h)) {
        return "warning";
    }
    return "outline";
}
export default function MonitoringPage() {
    const params = useParams<{
        id: string;
    }>();
    const projectId = params.id;
    const [logTab, setLogTab] = useState<"build" | "deploy" | "pod">("build");
    const [selectedPod, setSelectedPod] = useState<{
        namespace: string;
        name: string;
        containers: string[];
        container: string;
    } | null>(null);
    const snapshotQuery = useQuery({
        queryKey: ["monitoring-snapshot", projectId],
        queryFn: () => monitoringApi.getSnapshot(projectId),
        refetchInterval: 20000
    });
    const statusQuery = useQuery({
        queryKey: ["status", projectId],
        queryFn: () => pipelineApi.getStatus(projectId),
        refetchInterval: 20000
    });
    const argoQuery = useQuery({
        queryKey: ["argocd", projectId],
        queryFn: () => argocdApi.getStatus(projectId),
        refetchInterval: 25000
    });
    const podLogsQuery = useQuery({
        queryKey: ["k8s", "pod-logs", "monitoring", selectedPod?.namespace, selectedPod?.name, selectedPod?.container],
        queryFn: () => kubernetesApi.getPodLogs(selectedPod!.namespace, selectedPod!.name, selectedPod!.container || undefined),
        enabled: Boolean(selectedPod?.namespace && selectedPod?.name)
    });
    const grafanaBaseUrl = process.env.NEXT_PUBLIC_GRAFANA_URL || "http://localhost:3001";
    const grafanaUrl = `${grafanaBaseUrl.replace(/\/+$/, "")}/`;
    const snap = snapshotQuery.data;
    const phaseChartData = useMemo(() => {
        if (!snap) {
            return [];
        }
        const { summary } = snap.kubernetes;
        return [
            { name: "Running", value: summary.running, fill: phaseColors.Running },
            { name: "Pending", value: summary.pending, fill: phaseColors.Pending },
            { name: "Failed", value: summary.failed, fill: phaseColors.Failed },
            { name: "Succeeded", value: summary.succeeded, fill: phaseColors.Succeeded },
            { name: "Other", value: summary.other, fill: phaseColors.Other }
        ].filter((row) => row.value > 0);
    }, [snap]);
    const cpuChartData = useMemo(() => (snap?.prometheus.cpuSeries ?? []).map((p) => ({
        t: formatChartTime(p.ts),
        ts: p.ts,
        pct: Math.round(p.value * 10) / 10
    })), [snap?.prometheus.cpuSeries]);
    const memChartData = useMemo(() => (snap?.prometheus.memorySeries ?? []).map((p) => ({
        t: formatChartTime(p.ts),
        ts: p.ts,
        pct: Math.round(p.value * 10) / 10
    })), [snap?.prometheus.memorySeries]);
    function openPodLogs(pod: MonitoringKubernetesPod) {
        const first = pod.containers[0] ?? "";
        setSelectedPod({
            namespace: pod.namespace,
            name: pod.name,
            containers: pod.containers,
            container: first
        });
        setLogTab("pod");
    }
    const buildLogText = statusQuery.data?.buildLogs?.trim() || "No build log buffer stored for this project yet.";
    const deployLogText = statusQuery.data?.deploymentLogs?.trim() || "No deployment / GitOps log buffer stored yet.";
    const podLogText = selectedPod
        ? podLogsQuery.data?.logs ||
            (podLogsQuery.isFetching ? "Loading pod logs from Kubernetes\u2026" : "No log lines returned for this pod/container.")
        : "Select a workload in the table below and choose View logs.";
    const logBody = logTab === "build" ? buildLogText : logTab === "deploy" ? deployLogText : podLogText;
    const loading = snapshotQuery.isLoading && !snapshotQuery.data;
    return (<div className="space-y-8">
      <nav className="flex flex-wrap items-center gap-1 text-sm text-muted">
        <Link href="/projects" className="hover:text-foreground">
          Projects
        </Link>
        <ChevronRight className="h-4 w-4 shrink-0 opacity-60"/>
        {snap ? (<Link href={`/projects/${projectId}`} className="max-w-[220px] truncate hover:text-foreground">
            {snap.project.projectName}
          </Link>) : <span className="text-foreground">Project</span>}
        <ChevronRight className="h-4 w-4 shrink-0 opacity-60"/>
        <span className="text-foreground">Monitoring</span>
      </nav>

      <header className="flex flex-col gap-4 border-b border-border pb-8 lg:flex-row lg:items-start lg:justify-between">
        <div className="min-w-0 space-y-1">
          <p className="text-xs font-medium uppercase tracking-wide text-muted">Observability</p>
          <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">
            Monitoring
            {snap ? (<span className="mt-1 block text-base font-normal text-muted">
                {snap.project.projectName}
              </span>) : null}
          </h1>
          <p className="max-w-2xl text-sm text-muted">
            Prometheus trend charts (cluster-wide PromQL), workloads in this project&apos;s namespace, GitOps status, and CI/CD and pod logs together.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {snapshotQuery.isFetching && snapshotQuery.data ? (<span className="flex items-center gap-1 text-xs text-muted">
              <Loader2 className="h-3.5 w-3.5 animate-spin"/>
              Refreshing
            </span>) : null}
          <Button type="button" variant="outline" size="sm" onClick={() => void snapshotQuery.refetch()} disabled={snapshotQuery.isFetching}>
            <RefreshCcw className={cn("mr-2 h-4 w-4", snapshotQuery.isFetching && "animate-spin")}/>
            Refresh
          </Button>
          {snap?.project.url?.trim() ? (<Button asChild variant="outline" size="sm">
              <a href={snap.project.url} target="_blank" rel="noopener noreferrer">
                <ExternalLink className="mr-2 h-4 w-4"/>
                App URL
              </a>
            </Button>) : null}
        </div>
      </header>

      {snapshotQuery.isError ? (<Card className="border-danger/30 bg-danger/5">
          <CardHeader>
            <CardTitle className="text-base flex items-center gap-2">
              <AlertCircle className="h-5 w-5"/>
              Could not load monitoring snapshot
            </CardTitle>
            <CardDescription>Check permissions or try again.</CardDescription>
          </CardHeader>
        </Card>) : null}

      {loading ? (<section className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          {Array.from({ length: 4 }).map((_, i) => <Skeleton key={i} className="h-28 rounded-xl"/>)}
        </section>) : snap ? (<>
          <section className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
            <Card>
              <CardHeader className="pb-2">
                <CardTitle className="text-sm font-medium text-muted">CPU (instant)</CardTitle>
              </CardHeader>
              <CardContent className="text-2xl font-semibold tabular-nums">
                {snap.runtime.cpuUsagePercent}%
              </CardContent>
              <CardDescription className="px-6 pb-4 text-xs">
                {snap.prometheus.configured ? "From Prometheus (cluster node query)." : "Prometheus URL not configured — seed/fallback value."}
              </CardDescription>
            </Card>
            <Card>
              <CardHeader className="pb-2">
                <CardTitle className="text-sm font-medium text-muted">Memory (instant)</CardTitle>
              </CardHeader>
              <CardContent className="text-2xl font-semibold tabular-nums">{snap.runtime.memoryUsagePercent}%</CardContent>
              <CardDescription className="px-6 pb-4 text-xs">Same PromQL window as the CPU card.</CardDescription>
            </Card>
            <Card>
              <CardHeader className="pb-2">
                <CardTitle className="text-sm font-medium text-muted">Deploy / build</CardTitle>
              </CardHeader>
              <CardContent className="space-y-2">
                <div className="flex flex-wrap items-center gap-2">
                  <Badge variant="outline">{snap.project.lastDeploymentStatus}</Badge>
                  <Badge variant="outline">{snap.project.buildStatus}</Badge>
                </div>
                <p className="text-xs text-muted">Stored project row; not live Prometheus.</p>
              </CardContent>
            </Card>
            <Card>
              <CardHeader className="pb-2">
                <CardTitle className="text-sm font-medium text-muted">Namespace &amp; image</CardTitle>
              </CardHeader>
              <CardContent className="space-y-1 text-sm">
                <p className="font-mono text-xs text-foreground">{snap.project.namespace}</p>
                <p className="truncate font-mono text-xs text-muted">{snap.project.imageTag || "\u2014"}</p>
              </CardContent>
            </Card>
          </section>

          <section className="grid gap-4 lg:grid-cols-2">
            <Card>
              <CardHeader className="pb-2">
                <CardTitle className="text-base">Cluster CPU — last hour</CardTitle>
                <CardDescription>
                  Prometheus <span className="font-mono text-xs">query_range</span> using <span className="font-mono text-xs">PROMETHEUS_QUERY_CPU</span> (or default node CPU idle).
                </CardDescription>
              </CardHeader>
              <CardContent className="h-[260px]">
                {snap.prometheus.rangeError ? (<p className="text-sm text-warning">{snap.prometheus.rangeError}</p>) : cpuChartData.length === 0 ? (<p className="text-sm text-muted">
                    {snap.prometheus.configured ? "No time-series points returned (empty result or short history)." : "Set PROMETHEUS_BASE_URL to chart live usage."}
                  </p>) : (<ResponsiveContainer width="100%" height="100%">
                    <LineChart data={cpuChartData} margin={{ left: 0, right: 8, top: 8, bottom: 0 }}>
                      <CartesianGrid strokeDasharray="3 3" stroke="hsl(var(--border))"/>
                      <XAxis dataKey="t" tick={{ fontSize: 11 }} stroke="hsl(var(--muted-foreground))"/>
                      <YAxis domain={[0, 100]} tick={{ fontSize: 11 }} stroke="hsl(var(--muted-foreground))" width={36}/>
                      <Tooltip contentStyle={{ background: "hsl(var(--card))", border: "1px solid hsl(var(--border))", borderRadius: 8 }} formatter={(value: number) => [`${value}%`, "CPU"]}/>
                      <Line type="monotone" dataKey="pct" name="CPU %" stroke={chartCpu} strokeWidth={2} dot={false}/>
                    </LineChart>
                  </ResponsiveContainer>)}
              </CardContent>
            </Card>
            <Card>
              <CardHeader className="pb-2">
                <CardTitle className="text-base">Cluster memory — last hour</CardTitle>
                <CardDescription>
                  Uses <span className="font-mono text-xs">PROMETHEUS_QUERY_MEMORY</span> (or default MemAvailable / MemTotal).
                </CardDescription>
              </CardHeader>
              <CardContent className="h-[260px]">
                {snap.prometheus.rangeError ? (<p className="text-sm text-warning">{snap.prometheus.rangeError}</p>) : memChartData.length === 0 ? (<p className="text-sm text-muted">
                    {snap.prometheus.configured ? "No memory series returned." : "Connect Prometheus for trend data."}
                  </p>) : (<ResponsiveContainer width="100%" height="100%">
                    <LineChart data={memChartData} margin={{ left: 0, right: 8, top: 8, bottom: 0 }}>
                      <CartesianGrid strokeDasharray="3 3" stroke="hsl(var(--border))"/>
                      <XAxis dataKey="t" tick={{ fontSize: 11 }} stroke="hsl(var(--muted-foreground))"/>
                      <YAxis domain={[0, 100]} tick={{ fontSize: 11 }} stroke="hsl(var(--muted-foreground))" width={36}/>
                      <Tooltip contentStyle={{ background: "hsl(var(--card))", border: "1px solid hsl(var(--border))", borderRadius: 8 }} formatter={(value: number) => [`${value}%`, "Memory"]}/>
                      <Line type="monotone" dataKey="pct" name="Memory %" stroke={chartMem} strokeWidth={2} dot={false}/>
                    </LineChart>
                  </ResponsiveContainer>)}
              </CardContent>
            </Card>
          </section>

          <section className="grid gap-4 xl:grid-cols-3">
            <Card className="xl:col-span-1">
              <CardHeader className="pb-2">
                <CardTitle className="text-base flex items-center gap-2">
                  <Boxes className="h-5 w-5 text-primary"/>
                  Pods in namespace
                </CardTitle>
                <CardDescription>
                  <span className="font-mono text-xs">{snap.project.namespace}</span>
                  {snap.kubernetes.configured ? snap.kubernetes.error ? null : <span> — {snap.kubernetes.summary.total} workloads</span> : " — enable KUBERNETES_ENABLED for live data."}
                </CardDescription>
              </CardHeader>
              <CardContent className="h-[280px]">
                {snap.kubernetes.error ? (<p className="text-sm text-warning">{snap.kubernetes.error}</p>) : !snap.kubernetes.configured ? (<p className="text-sm text-muted">Kubernetes API is disabled or unavailable. Pod phases and logs from the cluster cannot load.</p>) : phaseChartData.length === 0 ? (<p className="text-sm text-muted">No pods in this namespace.</p>) : (<ResponsiveContainer width="100%" height="100%">
                    <BarChart data={phaseChartData} layout="vertical" margin={{ left: 8, right: 16, top: 8, bottom: 8 }}>
                      <CartesianGrid strokeDasharray="3 3" stroke="hsl(var(--border))" horizontal={false}/>
                      <XAxis type="number" allowDecimals={false} tick={{ fontSize: 11 }}/>
                      <YAxis type="category" dataKey="name" width={72} tick={{ fontSize: 11 }}/>
                      <Tooltip contentStyle={{ background: "hsl(var(--card))", border: "1px solid hsl(var(--border))", borderRadius: 8 }}/>
                      <Bar dataKey="value" radius={[0, 6, 6, 0]}>
                        {phaseChartData.map((entry) => <Cell key={entry.name} fill={entry.fill}/>)}
                      </Bar>
                    </BarChart>
                  </ResponsiveContainer>)}
              </CardContent>
            </Card>
            <Card className="xl:col-span-2">
              <CardHeader className="pb-2">
                <CardTitle className="text-base flex items-center gap-2">
                  <Server className="h-5 w-5 text-primary"/>
                  Workloads &amp; pod logs
                </CardTitle>
                <CardDescription>
                  Open logs for a container; uses the same Kubernetes log API as Cluster and Dashboard. Pod status from {snap.project.namespace}.
                </CardDescription>
              </CardHeader>
              <CardContent className="max-h-[min(24rem,50vh)] overflow-auto rounded-lg border border-border">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Pod</TableHead>
                      <TableHead>Status</TableHead>
                      <TableHead>Health</TableHead>
                      <TableHead>Ready</TableHead>
                      <TableHead className="text-right">Logs</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {snap.kubernetes.pods.length === 0 ? (<TableRow>
                        <TableCell colSpan={5} className="text-center text-sm text-muted">
                          No pods listed for this namespace.
                        </TableCell>
                      </TableRow>) : (snap.kubernetes.pods.map((pod) => (<TableRow key={`${pod.namespace}/${pod.name}`}>
                        <TableCell className="max-w-[200px] truncate font-mono text-xs">{pod.name}</TableCell>
                        <TableCell>
                          <Badge variant={podStatusBadgeVariant(pod.status)}>{pod.status}</Badge>
                        </TableCell>
                        <TableCell>
                          <Badge variant={podHealthBadgeVariant(pod.health)}>{pod.health}</Badge>
                        </TableCell>
                        <TableCell className="text-xs text-muted">{pod.ready}</TableCell>
                        <TableCell className="text-right">
                          <Button type="button" variant="outline" size="sm" className="gap-1" disabled={!snap.kubernetes.configured || Boolean(snap.kubernetes.error)} onClick={() => openPodLogs(pod)}>
                            <FileText className="h-3.5 w-3.5"/>
                            View
                          </Button>
                        </TableCell>
                      </TableRow>)))}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>
          </section>

          <section className="grid gap-4 lg:grid-cols-2">
            <Card>
              <CardHeader className="pb-2">
                <CardTitle className="text-base flex items-center gap-2">
                  <Activity className="h-5 w-5 text-primary"/>
                  GitOps (Argo CD)
                </CardTitle>
                <CardDescription>Application sync and health for this project.</CardDescription>
              </CardHeader>
              <CardContent className="space-y-3">
                {argoQuery.isLoading ? <Skeleton className="h-20 w-full"/> : (<>
                    <div className="flex flex-wrap gap-2">
                      <Badge variant="outline">App: {argoQuery.data?.appName ?? "\u2014"}</Badge>
                      <Badge variant={argoQuery.data?.health === "Healthy" ? "success" : "outline"}>Health: {argoQuery.data?.health ?? "\u2014"}</Badge>
                      <Badge variant="outline">Sync: {argoQuery.data?.syncStatus ?? "\u2014"}</Badge>
                    </div>
                    {argoQuery.data?.unreachableReason ? <p className="text-xs text-warning">{argoQuery.data.unreachableReason}</p> : null}
                  </>)}
              </CardContent>
            </Card>
            <Card>
              <CardHeader className="pb-2">
                <CardTitle className="text-base">Workspace supply chain rollups</CardTitle>
                <CardDescription>Derived from all non-deleted projects (Cosign/Trivy-style rollups in metrics service), not only this app.</CardDescription>
              </CardHeader>
              <CardContent className="grid grid-cols-2 gap-3 text-sm">
                <div className="rounded-lg border border-border bg-muted/10 p-3">
                  <p className="text-xs text-muted">Signed images</p>
                  <p className="text-xl font-semibold">{snap.runtime.signedImages}</p>
                </div>
                <div className="rounded-lg border border-border bg-muted/10 p-3">
                  <p className="text-xs text-muted">Unsigned</p>
                  <p className="text-xl font-semibold">{snap.runtime.unsignedImages}</p>
                </div>
                <div className="rounded-lg border border-border bg-muted/10 p-3">
                  <p className="text-xs text-muted">Failed builds (all)</p>
                  <p className="text-xl font-semibold">{snap.runtime.failedBuilds}</p>
                </div>
                <div className="rounded-lg border border-border bg-muted/10 p-3">
                  <p className="text-xs text-muted">Running apps (deploy OK)</p>
                  <p className="text-xl font-semibold">{snap.runtime.runningApplications}</p>
                </div>
              </CardContent>
            </Card>
          </section>

          <Card>
            <CardHeader className="pb-2">
              <CardTitle className="text-base">Logs</CardTitle>
              <CardDescription>
                Build and deployment buffers from the platform; pod log is live from Kubernetes when configured.
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <div className="flex flex-wrap gap-2">
                <Button type="button" size="sm" variant={logTab === "build" ? "default" : "outline"} onClick={() => setLogTab("build")}>
                  Build console
                </Button>
                <Button type="button" size="sm" variant={logTab === "deploy" ? "default" : "outline"} onClick={() => setLogTab("deploy")}>
                  Deploy / GitOps
                </Button>
                <Button type="button" size="sm" variant={logTab === "pod" ? "default" : "outline"} onClick={() => setLogTab("pod")}>
                  Pod log
                </Button>
              </div>
              {logTab === "pod" && selectedPod ? (<div className="flex flex-wrap items-center gap-2 text-xs">
                  <Badge variant="outline" className="font-mono">
                    {selectedPod.namespace}/{selectedPod.name}
                  </Badge>
                  {selectedPod.containers.length > 0 ? (<select aria-label="Container" className="h-8 rounded-md border border-border bg-background px-2 text-xs" value={selectedPod.container} onChange={(event) => setSelectedPod({
                        ...selectedPod,
                        container: event.target.value
                    })}>
                      {selectedPod.containers.map((c) => <option key={c} value={c}>
                          {c}
                        </option>)}
                    </select>) : null}
                  <Button type="button" variant="outline" size="sm" aria-label="Refresh pod logs" onClick={() => void podLogsQuery.refetch()} disabled={podLogsQuery.isFetching}>
                    {podLogsQuery.isFetching ? <Loader2 className="h-3.5 w-3.5 animate-spin"/> : <RefreshCcw className="h-3.5 w-3.5"/>}
                  </Button>
                </div>) : null}
              <Textarea readOnly value={statusQuery.isLoading && logTab !== "pod" ? "Loading\u2026" : logBody} className="min-h-[280px] font-mono text-xs"/>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Grafana</CardTitle>
              <CardDescription>
                Charts above use your configured Prometheus. Grafana remains the place for advanced dashboards and ad-hoc PromQL.
              </CardDescription>
            </CardHeader>
            <CardContent>
              <Button asChild variant="outline">
                <a href={grafanaUrl} target="_blank" rel="noreferrer">
                  <ExternalLink className="mr-2 h-4 w-4"/>
                  Open Grafana
                </a>
              </Button>
            </CardContent>
          </Card>
        </>) : null}
    </div>);
}
