"use client";
import { useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { Activity, Boxes, FileText, RefreshCcw, ServerCog, ShipWheel } from "lucide-react";
import { useQuery } from "@tanstack/react-query";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Textarea } from "@/components/ui/textarea";
import { kubernetesApi, projectApi } from "@/lib/api";
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
function rollUpClusterFromProjects(projects: Project[]): {
    runningPods: number;
    unhealthyPods: number;
    services: number;
    deployments: number;
    healthyDeployments: number;
} {
    const runningPods = projects.filter((p) => {
        const d = (p.lastDeploymentStatus || "").toUpperCase();
        if (d === "DEPLOYED" || d === "SUCCESS") {
            return true;
        }
        return /\d+\s*running/i.test(p.podStatus || "") || /\brunning\b/i.test(p.podStatus || "");
    }).length;
    const unhealthyPods = projects.filter((p) => {
        if ((p.lastDeploymentStatus || "").toUpperCase() === "FAILED") {
            return true;
        }
        const ps = (p.podStatus || "").toUpperCase();
        return ps.includes("FAIL") || ps.includes("ERROR") || ps.includes("CRASH") || ps === "UNKNOWN";
    }).length;
    const healthyDeployments = projects.filter((p) => {
        const d = (p.lastDeploymentStatus || "").toUpperCase();
        return d === "DEPLOYED" || d === "SUCCESS";
    }).length;
    return {
        runningPods,
        unhealthyPods,
        services: projects.filter((p) => Boolean(p.url?.trim())).length,
        deployments: projects.length,
        healthyDeployments
    };
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
    return <StatusPill label={status || "—"} tone={tone}/>;
}
function EmptyMessage({ children }: {
    children: React.ReactNode;
}) {
    return <p className="pt-4 text-sm text-muted">{children}</p>;
}
export default function ClusterPage() {
    const [selectedNamespace, setSelectedNamespace] = useState("all");
    const [selectedPod, setSelectedPod] = useState<{
        namespace: string;
        name: string;
        containers: string[];
        container: string;
    } | null>(null);
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
    const projectsQuery = useQuery({
        queryKey: ["projects", "cluster-fallback"],
        queryFn: () => projectApi.getProjects(),
        refetchInterval: 15000
    });
    const podLogsQuery = useQuery({
        queryKey: ["k8s", "pod-logs", selectedPod?.namespace, selectedPod?.name, selectedPod?.container],
        queryFn: () => kubernetesApi.getPodLogs(selectedPod?.namespace || "", selectedPod?.name || "", selectedPod?.container),
        enabled: Boolean(selectedPod?.namespace && selectedPod?.name)
    });
    const isRefreshing = podsQuery.isFetching || servicesQuery.isFetching || deploymentsQuery.isFetching || projectsQuery.isFetching;
    const clusterConfigured = useMemo(() => Boolean(podsQuery.data?.configured || servicesQuery.data?.configured || deploymentsQuery.data?.configured), [deploymentsQuery.data?.configured, podsQuery.data?.configured, servicesQuery.data?.configured]);
    const clusterError = podsQuery.data?.error || servicesQuery.data?.error || deploymentsQuery.data?.error || "";
    const clusterConnected = clusterConfigured && !clusterError;
    /** No usable Kubernetes API — we show platform projects instead of live cluster lists. */
    const useControlPlaneFallback = !clusterConnected;
    const projectList = projectsQuery.data ?? [];
    const useRollupStats = useControlPlaneFallback && projectList.length > 0;
    const allNamespaces = useMemo(() => {
        const names = new Set<string>();
        if (clusterConnected) {
            for (const pod of podsQuery.data?.pods ?? []) {
                names.add(pod.namespace);
            }
            for (const service of servicesQuery.data?.services ?? []) {
                names.add(service.namespace);
            }
            for (const deployment of deploymentsQuery.data?.deployments ?? []) {
                names.add(deployment.namespace);
            }
        }
        else {
            for (const project of projectsQuery.data ?? []) {
                const ns = project.namespace?.trim();
                if (ns) {
                    names.add(ns);
                }
            }
        }
        return Array.from(names).sort();
    }, [
        clusterConnected,
        deploymentsQuery.data?.deployments,
        podsQuery.data?.pods,
        projectsQuery.data,
        servicesQuery.data?.services
    ]);
    const filteredProjects = useMemo(() => (projectsQuery.data ?? []).filter((project) => selectedNamespace === "all" || project.namespace === selectedNamespace), [projectsQuery.data, selectedNamespace]);
    const projectRollup = useMemo(() => rollUpClusterFromProjects(filteredProjects), [filteredProjects]);
    const filteredPods = useMemo(() => (podsQuery.data?.pods ?? []).filter((pod) => selectedNamespace === "all" || pod.namespace === selectedNamespace), [podsQuery.data?.pods, selectedNamespace]);
    const filteredServices = useMemo(() => (servicesQuery.data?.services ?? []).filter((service) => selectedNamespace === "all" || service.namespace === selectedNamespace), [selectedNamespace, servicesQuery.data?.services]);
    const filteredDeployments = useMemo(() => (deploymentsQuery.data?.deployments ?? []).filter((deployment) => selectedNamespace === "all" || deployment.namespace === selectedNamespace), [deploymentsQuery.data?.deployments, selectedNamespace]);
    const runningPods = useRollupStats ? projectRollup.runningPods : filteredPods.filter((pod) => pod.status === "Running").length;
    const unhealthyPods = useRollupStats ? projectRollup.unhealthyPods : filteredPods.filter((pod) => pod.health !== "Healthy" && pod.health !== "Succeeded").length;
    const servicesTotal = useRollupStats ? projectRollup.services : filteredServices.length;
    const deploymentsTotal = useRollupStats ? projectRollup.deployments : filteredDeployments.length;
    const healthyDeployments = useRollupStats ? projectRollup.healthyDeployments : filteredDeployments.filter((deployment) => deployment.ready === `${deployment.replicas}/${deployment.replicas}`).length;
    const refreshAll = async () => {
        await Promise.all([
            podsQuery.refetch(),
            servicesQuery.refetch(),
            deploymentsQuery.refetch(),
            projectsQuery.refetch(),
            selectedPod ? podLogsQuery.refetch() : Promise.resolve()
        ]);
    };
    useEffect(() => {
        if (selectedPod) {
            logsRef.current?.scrollIntoView({ behavior: "smooth", block: "start" });
        }
    }, [selectedPod]);
    return (<div className="space-y-6">
      <section className="flex flex-col gap-4 rounded-3xl border border-border/80 bg-card/85 p-6 shadow-[0_20px_80px_rgba(0,0,0,0.12)] backdrop-blur lg:flex-row lg:items-center lg:justify-between">
        <div>
          <p className="text-xs font-medium uppercase tracking-[0.24em] text-muted">Cluster status</p>
          <h2 className="mt-2 text-3xl font-semibold tracking-tight text-foreground">Kubernetes Control View</h2>
          <p className="mt-2 max-w-3xl text-sm text-muted">
            {useControlPlaneFallback
                ? "Kubernetes is not connected. This page does not discover Docker Compose or Swarm services on a server by itself. You will see workload counts and rows only for projects registered here (with deploy status from your pipelines) unless you enable the Kubernetes API and kubeconfig."
                : "Real cluster data from your Kubernetes API: pods, services, deployments, health states, and live pod logs."}
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-3">
          {clusterConnected ? <StatusPill label="Connected" tone="success"/> : clusterConfigured ? <StatusPill label="Connection failed" tone="danger"/> : <StatusPill label="Not configured" tone="warning"/>}
          <select aria-label="Filter cluster resources by namespace" value={selectedNamespace} onChange={(event) => setSelectedNamespace(event.target.value)} className="h-10 rounded-xl border border-border bg-background px-3 text-sm text-foreground outline-none transition focus:border-primary/40">
            <option value="all">All namespaces</option>
            {allNamespaces.map((namespace) => <option key={namespace} value={namespace}>
                {namespace}
              </option>)}
          </select>
          <Button type="button" variant="outline" onClick={() => void refreshAll()} disabled={isRefreshing}>
            <RefreshCcw className={`mr-2 h-4 w-4 ${isRefreshing ? "animate-spin" : ""}`}/>
            Refresh
          </Button>
        </div>
      </section>

      {clusterError ? <div className="rounded-2xl border border-yellow-500/30 bg-yellow-500/10 px-4 py-3 text-sm text-yellow-700 dark:text-yellow-300">
          {clusterError}
        </div> : null}

      {useControlPlaneFallback ? <div className="rounded-2xl border border-border/80 bg-muted/15 px-4 py-3 text-sm text-muted">
          <strong className="font-medium text-foreground">Why counts may stay at zero:</strong> Docker Engine and Docker Swarm are not wired into this screen. Either create projects under{" "}
          <Link href="/projects" className="font-medium text-primary hover:underline">
            Projects
          </Link>{" "}
          and deploy through this platform (status is stored in the database), or set <code className="rounded bg-muted px-1 py-0.5 text-xs">KUBERNETES_ENABLED=true</code> with a valid kubeconfig to list pods and services from a cluster.
        </div> : null}

      {projectsQuery.isError ? <div className="rounded-2xl border border-danger/30 bg-danger/5 px-4 py-3 text-sm text-danger">
          Could not load projects for this view. Refresh or check your session.
        </div> : null}

      <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-5">
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-sm">{useControlPlaneFallback ? "Healthy workloads" : "Pods running"}</CardTitle>
          </CardHeader>
          <CardContent className="flex items-center gap-3 text-3xl font-semibold">
            <Activity className="h-6 w-6 text-success"/>
            {runningPods}
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-sm">{useControlPlaneFallback ? "Needs attention" : "Unhealthy pods"}</CardTitle>
          </CardHeader>
          <CardContent className="flex items-center gap-3 text-3xl font-semibold">
            <Activity className="h-6 w-6 text-danger"/>
            {unhealthyPods}
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-sm">{useControlPlaneFallback ? "Public URLs" : "Services"}</CardTitle>
          </CardHeader>
          <CardContent className="flex items-center gap-3 text-3xl font-semibold">
            <ServerCog className="h-6 w-6 text-primary"/>
            {servicesTotal}
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-sm">{useControlPlaneFallback ? "Applications" : "Deployments"}</CardTitle>
          </CardHeader>
          <CardContent className="flex items-center gap-3 text-3xl font-semibold">
            <ShipWheel className="h-6 w-6 text-primary"/>
            {deploymentsTotal}
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-sm">{useControlPlaneFallback ? "Last deploy OK" : "Healthy deployments"}</CardTitle>
          </CardHeader>
          <CardContent className="flex items-center gap-3 text-3xl font-semibold">
            <Boxes className="h-6 w-6 text-foreground"/>
            {healthyDeployments}
          </CardContent>
        </Card>
      </section>

      <Card ref={logsRef}>
        <CardHeader>
          <CardTitle>Pod Logs</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          {useControlPlaneFallback ? (<Textarea readOnly value="Kubernetes is not connected. Configure KUBERNETES_ENABLED and a valid kubeconfig to select pods and stream logs here. Docker-only stacks do not expose pod logs in this view." className="min-h-[200px] font-mono text-xs"/>) : (<>
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
                Refresh logs
              </Button>) : null}
          </div>
          <Textarea readOnly value={selectedPod ? podLogsQuery.data?.logs || (podLogsQuery.isFetching ? "Loading pod logs..." : "No logs loaded yet.") : "Choose a pod row and click View logs to inspect container output."} className="min-h-[360px] font-mono text-xs"/>
        </>)}
        </CardContent>
      </Card>

      {useControlPlaneFallback ? (<Card>
          <CardHeader>
            <CardTitle>Applications (control plane)</CardTitle>
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
                      <td className="py-3 pr-4">{project.namespace || "—"}</td>
                      <td className="py-3 pr-4"><RecordStatusPill status={project.lastDeploymentStatus}/></td>
                      <td className="py-3 pr-4"><RecordStatusPill status={project.podStatus}/></td>
                      <td className="py-3 pr-4"><RecordStatusPill status={project.buildStatus}/></td>
                      <td className="py-3">
                        {project.url?.trim()
                          ? (<a href={project.url} target="_blank" rel="noopener noreferrer" className="font-medium text-primary hover:underline">
                              Open
                            </a>)
                          : "—"}
                      </td>
                    </tr>)}
                </tbody>
              </table>
              {!filteredProjects.length ? <EmptyMessage>No projects match the selected namespace.</EmptyMessage> : null}
            </>) : null}
          </CardContent>
        </Card>) : (<>
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
          {filteredPods.length ? null : <EmptyMessage>No pods match the selected namespace.</EmptyMessage>}
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
            {filteredServices.length ? null : <EmptyMessage>No services match the selected namespace.</EmptyMessage>}
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
            {filteredDeployments.length ? null : <EmptyMessage>No deployments match the selected namespace.</EmptyMessage>}
          </CardContent>
        </Card>
      </div>
        </>)}
    </div>);
}
