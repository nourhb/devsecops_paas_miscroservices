"use client";
import { useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { Activity, Boxes, FileText, RefreshCcw, ServerCog, ShipWheel } from "lucide-react";
import { useQuery } from "@tanstack/react-query";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Textarea } from "@/components/ui/textarea";
import { Hint } from "@/components/hint";
import { jenkinsUi, kubernetesApi, pipelineApi, projectApi } from "@/lib/api";
import { hints } from "@/lib/app-hints";
import { rollUpClusterFromProjects } from "@/lib/cluster-project-rollup";
import type { Project } from "@/types";
function formatTimestamp(value: string) {
    if (!value) {
        return "-";
    }
    return new Date(value).toLocaleString([], {
        year: "numeric",
        month: "short",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit"
    });
}
function StatusPill({ label, tone }: {
    label: string;
    tone: "neutral" | "success" | "warning" | "danger" | "info";
}) {
    const className = tone === "success"
        ? "border-success/30 bg-success/10 text-success"
        : tone === "warning"
            ? "border-yellow-500/30 bg-yellow-500/10 text-yellow-600 dark:text-yellow-400"
            : tone === "danger"
                ? "border-danger/30 bg-danger/10 text-danger"
                : tone === "info"
                    ? "border-primary/30 bg-primary/10 text-primary"
                    : "border-border bg-muted/10 text-muted";
    return <span className={`inline-flex rounded-full border px-2.5 py-1 text-xs font-medium ${className}`}>{label}</span>;
}
function PodStatusPill({ status }: {
    status: string;
}) {
    const normalized = status.toLowerCase();
    const tone = normalized === "running"
        ? "success"
        : normalized === "pending"
            ? "warning"
            : normalized === "failed"
                ? "danger"
                : "neutral";
    return <StatusPill label={status || "Unknown"} tone={tone}/>;
}
function PodHealthPill({ health }: {
    health: string;
}) {
    const normalized = health.toLowerCase();
    const tone = normalized === "healthy" || normalized === "succeeded"
        ? "success"
        : /(crashloopbackoff|imagepullbackoff|errimagepull|failed)/.test(normalized)
            ? "danger"
            : /(pending|notready|terminating)/.test(normalized)
                ? "warning"
                : "neutral";
    return <StatusPill label={health || "Unknown"} tone={tone}/>;
}
function NamespacePhasePill({ phase }: {
    phase: string;
}) {
    const p = (phase || "").toLowerCase();
    const tone = p === "active"
        ? "success"
        : p === "terminating"
            ? "warning"
            : "neutral";
    return <StatusPill label={phase || "Unknown"} tone={tone}/>;
}
function RecordStatusPill({ status }: {
    status: string;
}) {
    const s = status.toUpperCase();
    const tone = s === "DEPLOYED" || s === "SUCCESS" || s === "RUNNING" || s === "PASSED"
        ? "success"
        : s === "FAILED" || s.includes("ERROR")
            ? "danger"
            : s === "PENDING" || s === "DEPLOYING"
                ? "warning"
                : "neutral";
    return <StatusPill label={status || "\u2014"} tone={tone}/>;
}
function EmptyMessage({ children }: {
    children: React.ReactNode;
}) {
    return <p className="pt-4 text-sm text-muted">{children}</p>;
}
export default function ClusterNamespacesPage() {
    const [selectedNamespace, setSelectedNamespace] = useState("all");
    const [selectedPod, setSelectedPod] = useState<{
        namespace: string;
        name: string;
        containers: string[];
        container: string;
    } | null>(null);
    const [platformLogDeploymentId, setPlatformLogDeploymentId] = useState<string | null>(null);
    const [jenkinsConsoleExtra, setJenkinsConsoleExtra] = useState<string | null>(null);
    const [jenkinsConsoleLoading, setJenkinsConsoleLoading] = useState(false);
    const logsRef = useRef<HTMLDivElement | null>(null);
    const podsQuery = useQuery({
        queryKey: ["k8s", "pods"],
        queryFn: () => kubernetesApi.getPods(),
        refetchInterval: 10000
    });
    const servicesQuery = useQuery({
        queryKey: ["k8s", "services"],
        queryFn: () => kubernetesApi.getServices(),
        refetchInterval: 10000
    });
    const deploymentsQuery = useQuery({
        queryKey: ["k8s", "deployments"],
        queryFn: () => kubernetesApi.getDeployments(),
        refetchInterval: 10000
    });
    const namespacesQuery = useQuery({
        queryKey: ["k8s", "namespaces"],
        queryFn: () => kubernetesApi.getNamespaces(),
        refetchInterval: 20000
    });
    const projectsQuery = useQuery({
        queryKey: ["projects", "cluster-namespaces-fallback"],
        queryFn: () => projectApi.getProjects(),
        refetchInterval: 15000
    });
    const podLogsQuery = useQuery({
        queryKey: ["k8s", "pod-logs", selectedPod?.namespace, selectedPod?.name, selectedPod?.container],
        queryFn: () => kubernetesApi.getPodLogs(selectedPod?.namespace || "", selectedPod?.name || "", selectedPod?.container),
        enabled: Boolean(selectedPod?.namespace && selectedPod?.name)
    });
    const recentDeploymentsQuery = useQuery({
        queryKey: ["deployments-recent", "cluster-namespaces-page"],
        queryFn: () => pipelineApi.listRecentDeployments(25),
        refetchInterval: 20000
    });
    const effectivePlatformLogId = platformLogDeploymentId ?? recentDeploymentsQuery.data?.deployments[0]?.id ?? null;
    const platformDeploymentQuery = useQuery({
        queryKey: ["deployment", "cluster-namespaces-logs", effectivePlatformLogId],
        queryFn: () => pipelineApi.getDeployment(effectivePlatformLogId!),
        enabled: Boolean(effectivePlatformLogId),
        refetchInterval: 12000
    });
    const selectedRecentMeta = recentDeploymentsQuery.data?.deployments.find((d) => d.id === effectivePlatformLogId);
    const isRefreshing = podsQuery.isFetching ||
        servicesQuery.isFetching ||
        deploymentsQuery.isFetching ||
        namespacesQuery.isFetching ||
        projectsQuery.isFetching ||
        recentDeploymentsQuery.isFetching ||
        platformDeploymentQuery.isFetching;
    const clusterConfigured = useMemo(() => Boolean(podsQuery.data?.configured || servicesQuery.data?.configured || deploymentsQuery.data?.configured), [deploymentsQuery.data?.configured, podsQuery.data?.configured, servicesQuery.data?.configured]);
    const clusterError = podsQuery.data?.error || servicesQuery.data?.error || deploymentsQuery.data?.error || "";
    const clusterConnected = clusterConfigured && !clusterError;
    const useControlPlaneFallback = !clusterConnected;
    const projectList: Project[] = projectsQuery.data ?? [];
    const useRollupStats = useControlPlaneFallback && projectList.length > 0;
    const namespaceListError = namespacesQuery.data?.error?.trim() || "";
    const clusterNamespaceNames = useMemo(() => {
        if (!clusterConnected) {
            return [] as string[];
        }
        return (namespacesQuery.data?.namespaces ?? []).map((n) => n.name).filter(Boolean);
    }, [clusterConnected, namespacesQuery.data?.namespaces]);
    const namespaceDropdownNames = useMemo(() => {
        if (clusterConnected) {
            return clusterNamespaceNames;
        }
        const names = new Set<string>();
        for (const project of projectList) {
            const ns = project.namespace?.trim();
            if (ns) {
                names.add(ns);
            }
        }
        return Array.from(names).sort();
    }, [clusterConnected, clusterNamespaceNames, projectList]);
    const filteredPods = useMemo(() => (podsQuery.data?.pods ?? []).filter((pod) => selectedNamespace === "all" || pod.namespace === selectedNamespace), [podsQuery.data?.pods, selectedNamespace]);
    const filteredServices = useMemo(() => (servicesQuery.data?.services ?? []).filter((service) => selectedNamespace === "all" || service.namespace === selectedNamespace), [selectedNamespace, servicesQuery.data?.services]);
    const filteredDeployments = useMemo(() => (deploymentsQuery.data?.deployments ?? []).filter((deployment) => selectedNamespace === "all" || deployment.namespace === selectedNamespace), [deploymentsQuery.data?.deployments, selectedNamespace]);
    const filteredNamespaceRows = useMemo(() => {
        const rows = namespacesQuery.data?.namespaces ?? [];
        if (selectedNamespace === "all") {
            return rows;
        }
        return rows.filter((r) => r.name === selectedNamespace);
    }, [namespacesQuery.data?.namespaces, selectedNamespace]);
    const filteredProjects = useMemo(() => projectList.filter((project) => selectedNamespace === "all" || project.namespace === selectedNamespace), [projectList, selectedNamespace]);
    const projectRollup = useMemo(() => rollUpClusterFromProjects(filteredProjects), [filteredProjects]);
    const namespaceSummaries = useMemo(() => {
        const map = new Map<string, Project[]>();
        for (const p of projectList) {
            const ns = p.namespace?.trim() || "—";
            if (!map.has(ns)) {
                map.set(ns, []);
            }
            map.get(ns)!.push(p);
        }
        let rows = Array.from(map.entries()).map(([name, projs]) => ({
            name,
            count: projs.length
        }));
        if (selectedNamespace !== "all") {
            rows = rows.filter((r) => r.name === selectedNamespace);
        }
        return rows.sort((a, b) => a.name.localeCompare(b.name));
    }, [projectList, selectedNamespace]);
    const runningPods = useRollupStats ? projectRollup.runningPods : filteredPods.filter((pod) => pod.status === "Running").length;
    const unhealthyPods = useRollupStats ? projectRollup.unhealthyPods : filteredPods.filter((pod) => pod.health !== "Healthy" && pod.health !== "Succeeded").length;
    const servicesTotal = useRollupStats ? projectRollup.services : filteredServices.length;
    const deploymentsTotal = useRollupStats ? projectRollup.deployments : filteredDeployments.length;
    const healthyDeployments = useRollupStats
        ? projectRollup.healthyDeployments
        : filteredDeployments.filter((deployment) => deployment.ready === `${deployment.replicas}/${deployment.replicas}`).length;
    useEffect(() => {
        setJenkinsConsoleExtra(null);
    }, [effectivePlatformLogId]);
    const refreshAll = async () => {
        await Promise.all([
            podsQuery.refetch(),
            servicesQuery.refetch(),
            deploymentsQuery.refetch(),
            namespacesQuery.refetch(),
            projectsQuery.refetch(),
            recentDeploymentsQuery.refetch(),
            effectivePlatformLogId ? platformDeploymentQuery.refetch() : Promise.resolve(),
            selectedPod ? podLogsQuery.refetch() : Promise.resolve()
        ]);
    };
    const pullJenkinsConsole = async () => {
        const jobName = recentDeploymentsQuery.data?.jenkinsJobName?.trim();
        const bn = selectedRecentMeta?.buildNumber;
        if (!jobName || bn == null) {
            setJenkinsConsoleExtra("No Jenkins job name or build number is stored on this deployment yet.");
            return;
        }
        setJenkinsConsoleLoading(true);
        try {
            const payload = (await jenkinsUi.logs(jobName, bn)) as {
                logs?: string;
            };
            setJenkinsConsoleExtra(payload.logs ?? "(empty console response)");
        }
        catch (e) {
            setJenkinsConsoleExtra(`[Jenkins] ${e instanceof Error ? e.message : String(e)}`);
        }
        finally {
            setJenkinsConsoleLoading(false);
        }
    };
    const recentList = recentDeploymentsQuery.data?.deployments ?? [];
    const platformLogText = useMemo(() => {
        if (recentDeploymentsQuery.isLoading) {
            return "Loading recent deployments from the platform database\u2026";
        }
        if (!recentList.length) {
            return [
                "No deployment records yet for your workspace.",
                "",
                "This is normal before the first build/deploy. Records appear when you trigger Build or Deploy from a project.",
                "",
                "Useful links:",
                "  \u2022 /projects",
                "  \u2022 /projects/create"
            ].join("\n");
        }
        if (!effectivePlatformLogId) {
            return "Pick a deployment from the list above.";
        }
        if (platformDeploymentQuery.isLoading) {
            return "Loading deployment details\u2026";
        }
        const p = platformDeploymentQuery.data;
        if (!p) {
            return "Could not load deployment details. Try Refresh or pick another run.";
        }
        const lines: string[] = [
            `=== Deployment ${p.id} ===`,
            `Status: ${p.status}`,
            `Project: ${selectedRecentMeta?.projectName ?? "(unknown)"} (${p.projectId})`,
            p.buildNumber != null ? `Jenkins build number (stored on row): ${p.buildNumber}` : "Jenkins build number (stored on row): not linked yet",
            p.buildProvider ? `Build backend: ${p.buildProvider}` : "",
            p.buildRunId ? `Run id: ${p.buildRunId}` : "",
            p.artifactImage ? `Image: ${p.artifactImage}` : "",
            p.url ? `App URL: ${p.url}` : ""
        ].filter(Boolean);
        if (p.failureReason) {
            lines.push(`Failure reason: ${p.failureReason}`);
        }
        if (p.failureMessage) {
            lines.push(`Failure message: ${p.failureMessage}`);
        }
        lines.push("", "--- Log buffer stored in database (Jenkins / pipeline reconciliation) ---");
        const buf = p.logs?.trim();
        lines.push(buf && buf.length > 0
            ? buf
            : "(No log text stored on this row yet.)");
        if (jenkinsConsoleExtra) {
            lines.push("", "--- Live Jenkins consoleText (fetched on demand via API) ---", jenkinsConsoleExtra);
        }
        return lines.join("\n");
    }, [
        recentDeploymentsQuery.isLoading,
        recentList.length,
        effectivePlatformLogId,
        platformDeploymentQuery.isLoading,
        platformDeploymentQuery.data,
        selectedRecentMeta?.projectName,
        jenkinsConsoleExtra
    ]);
    const podLogHint = "Select a pod in the table below and choose \u201CView logs\u201D, or use the platform CI/CD section for Jenkins output stored in this application.";
    const podLogBody = selectedPod
        ? podLogsQuery.data?.logs || (podLogsQuery.isFetching ? "Loading pod logs from Kubernetes\u2026" : "No log lines returned for this pod/container yet.")
        : podLogHint;
    useEffect(() => {
        if (selectedPod) {
            logsRef.current?.scrollIntoView({ behavior: "smooth", block: "start" });
        }
    }, [selectedPod]);
    return (<div className="space-y-6">
      <section className="flex flex-col gap-4 rounded-3xl border border-border/80 bg-card/85 p-6 shadow-[0_20px_80px_rgba(0,0,0,0.12)] backdrop-blur lg:flex-row lg:items-center lg:justify-between">
        <div>
          <p className="text-xs font-medium uppercase tracking-[0.24em] text-muted">Cluster status</p>
          <h2 className="mt-2 flex flex-wrap items-center gap-2 text-3xl font-semibold tracking-tight text-foreground">
            Kubernetes namespaces
            <Hint side="bottom">{hints.clusterNamespaces.header}</Hint>
          </h2>
          <p className="mt-2 max-w-3xl text-sm text-muted">
            {clusterConnected ? (<>
                When the cluster API is connected, the namespace list uses{" "}
                <code className="inline-code">list Namespace</code>
                {" "}and workload tables use live pod, service, and deployment objects—same data as the control view, scoped by the filter.
              </>) : (<>
                <strong className="font-medium text-foreground">Kubernetes is not connected.</strong>{" "}
                Namespace choices and the metrics cards below are filled from your <strong className="font-medium text-foreground">projects</strong> (deploy target namespace and roll-up status), not from the cluster API.
                Configure the server for Kubernetes to see real namespace rows and workloads.
              </>)}
          </p>
          <p className="mt-3 text-sm">
            <Link href="/cluster" className="font-medium text-primary hover:underline">
              Open cluster control view
            </Link>
            <span className="text-muted"> — same fallback behaviour for disconnected clusters.</span>
          </p>
        </div>
        <div className="flex flex-col items-stretch gap-2 sm:items-end">
          <div className="flex flex-wrap items-center justify-end gap-3">
            {clusterConnected ? <StatusPill label="Connected" tone="success"/> : clusterConfigured ? <StatusPill label="Connection failed" tone="danger"/> : <StatusPill label="Not configured" tone="warning"/>}
            <select aria-label="Filter workloads by Kubernetes namespace" value={selectedNamespace} onChange={(event) => setSelectedNamespace(event.target.value)} className="h-10 rounded-xl border border-border bg-background px-3 text-sm text-foreground outline-none transition focus:border-primary/40">
              <option value="all">Cluster-wide</option>
              {namespaceDropdownNames.map((namespace) => <option key={namespace} value={namespace}>
                  {namespace}
                </option>)}
            </select>
            <Button type="button" variant="outline" onClick={() => void refreshAll()} disabled={isRefreshing}>
              <RefreshCcw className={`mr-2 h-4 w-4 ${isRefreshing ? "animate-spin" : ""}`}/>
              Refresh
            </Button>
          </div>
          {!clusterConnected ? <p className="max-w-md text-right text-xs text-muted">
              {namespaceDropdownNames.length > 0
                ? "Namespace list: deploy-target namespaces from your projects. Connect Kubernetes to load the real cluster namespace list."
                : "Add projects with a deploy namespace, or connect Kubernetes so this filter can list namespaces."}
            </p> : null}
        </div>
      </section>

      {clusterError ? <div className="rounded-2xl border border-yellow-500/30 bg-yellow-500/10 px-4 py-3 text-sm text-yellow-700 dark:text-yellow-300">
          {clusterError}
        </div> : null}

      {clusterConnected && namespaceListError ? <div className="rounded-2xl border border-yellow-500/30 bg-yellow-500/10 px-4 py-3 text-sm text-yellow-700 dark:text-yellow-300">
          Namespace list: {namespaceListError}
        </div> : null}

      {useRollupStats ? <div className="rounded-2xl border border-primary/20 bg-primary/5 px-4 py-3 text-sm text-muted">
          <strong className="font-medium text-foreground">Platform rollups active:</strong>{" "}
          counts and tables below come from your project records. Pod logs and API namespace phases require a connected Kubernetes cluster.
        </div> : !clusterConnected ? <div className="rounded-2xl border border-border/80 bg-muted/15 px-4 py-3 text-sm text-muted">
          <strong className="font-medium text-foreground">Kubernetes not connected</strong> and no projects were found—add a project or connect the API.
          Platform CI/CD logs below still work from the database.
        </div> : null}

      {projectsQuery.isError ? <div className="rounded-2xl border border-danger/30 bg-danger/5 px-4 py-3 text-sm text-danger">
          Could not load projects for namespace fallback. Refresh or check your session.
        </div> : null}

      <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-5">
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-sm">{useRollupStats ? "Healthy workloads" : "Pods running"}</CardTitle>
          </CardHeader>
          <CardContent className="flex items-center gap-3 text-3xl font-semibold">
            <Activity className="h-6 w-6 text-success"/>
            {runningPods}
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-sm">{useRollupStats ? "Needs attention" : "Unhealthy pods"}</CardTitle>
          </CardHeader>
          <CardContent className="flex items-center gap-3 text-3xl font-semibold">
            <Activity className="h-6 w-6 text-danger"/>
            {unhealthyPods}
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-sm">{useRollupStats ? "Public URLs" : "Services"}</CardTitle>
          </CardHeader>
          <CardContent className="flex items-center gap-3 text-3xl font-semibold">
            <ServerCog className="h-6 w-6 text-primary"/>
            {servicesTotal}
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-sm">{useRollupStats ? "Applications" : "Deployments"}</CardTitle>
          </CardHeader>
          <CardContent className="flex items-center gap-3 text-3xl font-semibold">
            <ShipWheel className="h-6 w-6 text-primary"/>
            {deploymentsTotal}
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-sm">{useRollupStats ? "Last deploy OK" : "Healthy deployments"}</CardTitle>
          </CardHeader>
          <CardContent className="flex items-center gap-3 text-3xl font-semibold">
            <Boxes className="h-6 w-6 text-foreground"/>
            {healthyDeployments}
          </CardContent>
        </Card>
      </section>

      <Card ref={logsRef}>
        <CardHeader>
          <CardTitle>Logs</CardTitle>
          <CardDescription>
            Kubernetes pod stream when the API is connected; platform deployment output (database + optional live Jenkins) is always available below.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-6">
          {clusterConnected ? (<div className="space-y-3">
              <p className="text-xs font-semibold uppercase tracking-wide text-muted">Kubernetes — pod stream</p>
              <div className="flex flex-wrap items-center gap-3">
                <StatusPill label={selectedPod ? selectedPod.name : "No pod selected"} tone={selectedPod ? "info" : "neutral"}/>
                <StatusPill label={selectedPod ? selectedPod.namespace : "Namespace"} tone="neutral"/>
                {selectedPod?.containers.length ? (<select aria-label="Select pod container" value={selectedPod.container} onChange={(event) => setSelectedPod({
                    ...selectedPod,
                    container: event.target.value
                })} className="h-10 rounded-xl border border-border bg-background px-3 text-sm text-foreground outline-none transition focus:border-primary/40">
                    {selectedPod.containers.map((container) => <option key={container} value={container}>
                        {container}
                      </option>)}
                  </select>) : null}
                {selectedPod ? (<Button type="button" variant="outline" size="sm" onClick={() => void podLogsQuery.refetch()} disabled={podLogsQuery.isFetching}>
                    <RefreshCcw className={`mr-2 h-4 w-4 ${podLogsQuery.isFetching ? "animate-spin" : ""}`}/>
                    Refresh pod logs
                  </Button>) : null}
              </div>
              <Textarea readOnly value={podLogBody} className="min-h-[220px] font-mono text-xs"/>
            </div>) : (<div className="rounded-lg border border-border/80 bg-muted/10 p-4 text-sm text-muted">
              <p className="font-medium text-foreground">Kubernetes pod streaming is unavailable</p>
              <p className="mt-2">
                With no cluster connection, pod logs cannot be streamed here. Use the{" "}
                <strong className="text-foreground">platform CI/CD</strong> section for Jenkins output.
              </p>
            </div>)}

          <div className="space-y-3 border-t border-border/60 pt-6">
            <p className="text-xs font-semibold uppercase tracking-wide text-muted">Platform — CI/CD (stored in this application)</p>
            {recentList.length > 0 ? (<div className="flex flex-wrap items-center gap-3">
                <select aria-label="Select deployment run" className="h-10 min-w-[280px] rounded-xl border border-border bg-background px-3 text-sm text-foreground outline-none transition focus:border-primary/40" value={effectivePlatformLogId ?? ""} onChange={(event) => setPlatformLogDeploymentId(event.target.value || null)}>
                  {recentList.map((row) => <option key={row.id} value={row.id}>
                      {formatTimestamp(row.createdAt)} — {row.projectName} — {row.status}
                      {row.buildNumber != null ? ` #${row.buildNumber}` : ""}
                    </option>)}
                </select>
                <Button type="button" variant="outline" size="sm" onClick={() => void platformDeploymentQuery.refetch()} disabled={platformDeploymentQuery.isFetching}>
                  <RefreshCcw className={`mr-2 h-4 w-4 ${platformDeploymentQuery.isFetching ? "animate-spin" : ""}`}/>
                  Refresh record
                </Button>
                <Button type="button" variant="outline" size="sm" onClick={() => void pullJenkinsConsole()} disabled={jenkinsConsoleLoading || !effectivePlatformLogId}>
                  {jenkinsConsoleLoading ? (<RefreshCcw className="mr-2 h-4 w-4 animate-spin"/>) : null}
                  Fetch Jenkins console
                </Button>
                {effectivePlatformLogId ? <Button type="button" variant="ghost" size="sm" asChild>
                    <Link href={`/deployments/${effectivePlatformLogId}`}>Open deployment page</Link>
                  </Button> : null}
              </div>) : null}
            <Textarea readOnly value={platformLogText} className="min-h-[360px] font-mono text-xs"/>
          </div>
        </CardContent>
      </Card>

      {clusterConnected ? (<>
        <Card>
          <CardHeader>
            <CardTitle>Namespaces (cluster API)</CardTitle>
            <CardDescription>
              {namespacesQuery.data?.summary.total ?? 0} namespace(s) from the cluster API
              {selectedNamespace !== "all" ? ` — showing rows for ${selectedNamespace}` : ""}.
            </CardDescription>
          </CardHeader>
          <CardContent className="overflow-x-auto">
            {namespacesQuery.isLoading ? <p className="text-sm text-muted">Loading namespaces…</p> : null}
            {!namespacesQuery.isLoading && !filteredNamespaceRows.length ? <EmptyMessage>
                No namespaces returned (check RBAC for list namespace). If you filtered one namespace, it may not exist in the API list.
              </EmptyMessage> : null}
            {!namespacesQuery.isLoading && filteredNamespaceRows.length > 0 ? (<table className="w-full min-w-[640px] text-left text-sm">
                <thead>
                  <tr className="border-b border-border text-muted">
                    <th className="py-3 pr-4 font-medium">Name</th>
                    <th className="py-3 pr-4 font-medium">Phase</th>
                    <th className="py-3 font-medium">Created</th>
                  </tr>
                </thead>
                <tbody>
                  {filteredNamespaceRows.map((row) => <tr key={row.name} className="border-b border-border/60">
                      <td className="py-3 pr-4 font-mono text-sm font-medium text-foreground">{row.name}</td>
                      <td className="py-3 pr-4"><NamespacePhasePill phase={row.phase}/></td>
                      <td className="py-3">{formatTimestamp(row.createdAt)}</td>
                    </tr>)}
                </tbody>
              </table>) : null}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Pods</CardTitle>
          </CardHeader>
          <CardContent className="overflow-x-auto">
            <table className="w-full min-w-[1180px] text-left text-sm">
              <thead>
                <tr className="border-b border-border text-muted">
                  <th className="py-3 pr-4 font-medium">Name</th>
                  <th className="py-3 pr-4 font-medium">Namespace</th>
                  <th className="py-3 pr-4 font-medium">Status</th>
                  <th className="py-3 pr-4 font-medium">Health</th>
                  <th className="py-3 pr-4 font-medium">Ready</th>
                  <th className="py-3 pr-4 font-medium">Restarts</th>
                  <th className="py-3 pr-4 font-medium">Node</th>
                  <th className="py-3 pr-4 font-medium">Pod IP</th>
                  <th className="py-3 pr-4 font-medium">Created</th>
                  <th className="py-3 font-medium">Logs</th>
                </tr>
              </thead>
              <tbody>
                {filteredPods.map((pod) => <tr key={`${pod.namespace}-${pod.name}`} className="border-b border-border/60">
                    <td className="py-3 pr-4 font-medium text-foreground">{pod.name}</td>
                    <td className="py-3 pr-4">{pod.namespace}</td>
                    <td className="py-3 pr-4"><PodStatusPill status={pod.status}/></td>
                    <td className="py-3 pr-4">
                      <div className="space-y-2">
                        <PodHealthPill health={pod.health}/>
                        <p className="max-w-xs text-xs text-muted">{pod.healthReason}</p>
                      </div>
                    </td>
                    <td className="py-3 pr-4">{pod.ready}</td>
                    <td className="py-3 pr-4">{pod.restarts}</td>
                    <td className="py-3 pr-4">{pod.nodeName}</td>
                    <td className="py-3 pr-4">{pod.podIP}</td>
                    <td className="py-3 pr-4">{formatTimestamp(pod.createdAt)}</td>
                    <td className="py-3">
                      <Button type="button" variant="outline" size="sm" onClick={() => setSelectedPod({
                    namespace: pod.namespace,
                    name: pod.name,
                    containers: pod.containers,
                    container: pod.containers[0] || ""
                })}>
                        <FileText className="mr-2 h-4 w-4"/>
                        View logs
                      </Button>
                    </td>
                  </tr>)}
              </tbody>
            </table>
            {filteredPods.length ? null : <EmptyMessage>No pods in scope for the current filter.</EmptyMessage>}
          </CardContent>
        </Card>

        <div className="grid gap-6 xl:grid-cols-2">
          <Card>
            <CardHeader>
              <CardTitle>Services</CardTitle>
            </CardHeader>
            <CardContent className="overflow-x-auto">
              <table className="w-full min-w-[760px] text-left text-sm">
                <thead>
                  <tr className="border-b border-border text-muted">
                    <th className="py-3 pr-4 font-medium">Name</th>
                    <th className="py-3 pr-4 font-medium">Namespace</th>
                    <th className="py-3 pr-4 font-medium">Type</th>
                    <th className="py-3 pr-4 font-medium">Cluster IP</th>
                    <th className="py-3 pr-4 font-medium">External IP</th>
                    <th className="py-3 font-medium">Ports</th>
                  </tr>
                </thead>
                <tbody>
                  {filteredServices.map((service) => <tr key={`${service.namespace}-${service.name}`} className="border-b border-border/60">
                      <td className="py-3 pr-4 font-medium text-foreground">{service.name}</td>
                      <td className="py-3 pr-4">{service.namespace}</td>
                      <td className="py-3 pr-4"><StatusPill label={service.type} tone="info"/></td>
                      <td className="py-3 pr-4">{service.clusterIP}</td>
                      <td className="py-3 pr-4">{service.externalIP}</td>
                      <td className="py-3">{service.ports.join(", ") || "-"}</td>
                    </tr>)}
                </tbody>
              </table>
              {filteredServices.length ? null : <EmptyMessage>No services in scope for the current filter.</EmptyMessage>}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Deployments</CardTitle>
            </CardHeader>
            <CardContent className="overflow-x-auto">
              <table className="w-full min-w-[760px] text-left text-sm">
                <thead>
                  <tr className="border-b border-border text-muted">
                    <th className="py-3 pr-4 font-medium">Name</th>
                    <th className="py-3 pr-4 font-medium">Namespace</th>
                    <th className="py-3 pr-4 font-medium">Ready</th>
                    <th className="py-3 pr-4 font-medium">Available</th>
                    <th className="py-3 pr-4 font-medium">Updated</th>
                    <th className="py-3 font-medium">Strategy</th>
                  </tr>
                </thead>
                <tbody>
                  {filteredDeployments.map((deployment) => <tr key={`${deployment.namespace}-${deployment.name}`} className="border-b border-border/60">
                      <td className="py-3 pr-4 font-medium text-foreground">{deployment.name}</td>
                      <td className="py-3 pr-4">{deployment.namespace}</td>
                      <td className="py-3 pr-4">{deployment.ready}</td>
                      <td className="py-3 pr-4">{deployment.available}</td>
                      <td className="py-3 pr-4">{deployment.updated}</td>
                      <td className="py-3">{deployment.strategy}</td>
                    </tr>)}
                </tbody>
              </table>
              {filteredDeployments.length ? null : <EmptyMessage>No deployments in scope for the current filter.</EmptyMessage>}
            </CardContent>
          </Card>
        </div>
      </>) : (<>
        <Card>
          <CardHeader>
            <CardTitle>Deploy target namespaces (platform)</CardTitle>
            <CardDescription>
              Grouped from project deploy targets. Connect Kubernetes to see API namespace phases and the full cluster list.
            </CardDescription>
          </CardHeader>
          <CardContent className="overflow-x-auto">
            {projectsQuery.isLoading ? <p className="text-sm text-muted">Loading projects…</p> : null}
            {!projectsQuery.isLoading && !namespaceSummaries.length ? <EmptyMessage>
                No deploy namespaces found in your projects yet.
                {" "}
                <Link href="/projects/create" className="font-medium text-primary hover:underline">
                  Create a project
                </Link>
                {" "}
                or set a namespace on an existing project.
              </EmptyMessage> : null}
            {!projectsQuery.isLoading && namespaceSummaries.length > 0 ? (<table className="w-full min-w-[480px] text-left text-sm">
                <thead>
                  <tr className="border-b border-border text-muted">
                    <th className="py-3 pr-4 font-medium">Namespace</th>
                    <th className="py-3 font-medium">Projects</th>
                  </tr>
                </thead>
                <tbody>
                  {namespaceSummaries.map((row) => <tr key={row.name} className="border-b border-border/60">
                      <td className="py-3 pr-4 font-mono text-sm font-medium text-foreground">{row.name}</td>
                      <td className="py-3">{row.count}</td>
                    </tr>)}
                </tbody>
              </table>) : null}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Applications (control plane)</CardTitle>
            <CardDescription>
              Same project rollup as the cluster control view; scoped by the namespace filter above.
            </CardDescription>
          </CardHeader>
          <CardContent className="overflow-x-auto">
            {projectsQuery.isLoading ? <p className="text-sm text-muted">Loading projects…</p> : null}
            {!projectsQuery.isLoading && !projectList.length ? <EmptyMessage>
                No projects in this workspace yet, so there is nothing to roll up. Docker services running outside this app are not listed here — add a project and deploy through the platform, or connect Kubernetes.
                {" "}
                <Link href="/projects/create" className="font-medium text-primary hover:underline">
                  Create a project
                </Link>
              </EmptyMessage> : null}
            {!projectsQuery.isLoading && projectList.length > 0 ? (<>
              <table className="w-full min-w-[920px] text-left text-sm">
                <thead>
                  <tr className="border-b border-border text-muted">
                    <th className="py-3 pr-4 font-medium">Project</th>
                    <th className="py-3 pr-4 font-medium">Namespace</th>
                    <th className="py-3 pr-4 font-medium">Deploy</th>
                    <th className="py-3 pr-4 font-medium">Pod</th>
                    <th className="py-3 pr-4 font-medium">Build</th>
                    <th className="py-3 font-medium">URL</th>
                  </tr>
                </thead>
                <tbody>
                  {filteredProjects.map((project) => <tr key={project.id} className="border-b border-border/60">
                      <td className="py-3 pr-4 font-medium">
                        <Link href={`/projects/${project.id}`} className="text-primary hover:underline">
                          {project.projectName}
                        </Link>
                      </td>
                      <td className="py-3 pr-4">{project.namespace || "\u2014"}</td>
                      <td className="py-3 pr-4"><RecordStatusPill status={project.lastDeploymentStatus}/></td>
                      <td className="py-3 pr-4"><RecordStatusPill status={project.podStatus}/></td>
                      <td className="py-3 pr-4"><RecordStatusPill status={project.buildStatus}/></td>
                      <td className="py-3">
                        {project.url?.trim()
                        ? (<a href={project.url} target="_blank" rel="noopener noreferrer" className="font-medium text-primary hover:underline">
                              Open
                            </a>)
                        : "\u2014"}
                      </td>
                    </tr>)}
                </tbody>
              </table>
              {!filteredProjects.length ? <EmptyMessage>No projects match the selected namespace.</EmptyMessage> : null}
            </>) : null}
          </CardContent>
        </Card>
      </>)}
    </div>);
}
