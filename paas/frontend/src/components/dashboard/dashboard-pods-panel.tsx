"use client";
import Link from "next/link";
import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { FileText, Loader2, RefreshCcw, Server } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Textarea } from "@/components/ui/textarea";
import { kubernetesApi, type KubernetesPodRecord } from "@/lib/api";
import { cn } from "@/lib/utils";
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
export function DashboardPodsPanel() {
    const [nsFilter, setNsFilter] = useState("all");
    const [selected, setSelected] = useState<{
        namespace: string;
        name: string;
        containers: string[];
        container: string;
    } | null>(null);
    const podsQuery = useQuery({
        queryKey: ["k8s", "pods", "dashboard"],
        queryFn: () => kubernetesApi.getPods(),
        refetchInterval: 12000
    });
    const namespaces = useMemo(() => {
        const names = new Set<string>();
        for (const p of podsQuery.data?.pods ?? []) {
            if (p.namespace) {
                names.add(p.namespace);
            }
        }
        return Array.from(names).sort();
    }, [podsQuery.data?.pods]);
    const filtered = useMemo(() => {
        const list = podsQuery.data?.pods ?? [];
        if (nsFilter === "all") {
            return list;
        }
        return list.filter((p) => p.namespace === nsFilter);
    }, [podsQuery.data?.pods, nsFilter]);
    const sorted = useMemo(() => [...filtered].sort((a, b) => a.namespace.localeCompare(b.namespace) || a.name.localeCompare(b.name)), [filtered]);
    const podLogsQuery = useQuery({
        queryKey: ["k8s", "pod-logs", "dashboard", selected?.namespace, selected?.name, selected?.container],
        queryFn: () => kubernetesApi.getPodLogs(selected!.namespace, selected!.name, selected!.container || undefined),
        enabled: Boolean(selected?.namespace && selected?.name)
    });
    function openLogs(pod: KubernetesPodRecord) {
        const first = pod.containers[0] ?? "";
        setSelected({
            namespace: pod.namespace,
            name: pod.name,
            containers: pod.containers,
            container: first
        });
    }
    const logBody = selected
        ? podLogsQuery.data?.logs || (podLogsQuery.isFetching ? "Loading pod logs from Kubernetes\u2026" : "No log lines returned yet.")
        : "Select a pod and choose View to stream container logs from the cluster.";
    return (<Card className="rounded-xl border-border/70 shadow-sm">
      <CardHeader className="flex flex-col gap-4 border-b border-border/60 pb-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="space-y-1">
          <CardTitle className="text-base">Cluster pods &amp; logs</CardTitle>
          <CardDescription>
            Live workloads from the Kubernetes API when <span className="font-mono text-xs">KUBERNETES_ENABLED</span> is on. Use the namespace filter, then open logs
            for a container.
          </CardDescription>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <select aria-label="Filter by namespace" value={nsFilter} onChange={(event) => setNsFilter(event.target.value)} className="h-9 rounded-md border border-border bg-background px-3 text-sm outline-none focus:ring-2 focus:ring-primary/30">
            <option value="all">All namespaces</option>
            {namespaces.map((n) => <option key={n} value={n}>
                {n}
              </option>)}
          </select>
          <Button type="button" variant="outline" size="sm" onClick={() => void podsQuery.refetch()} disabled={podsQuery.isFetching}>
            <RefreshCcw className={cn("mr-2 h-4 w-4", podsQuery.isFetching && "animate-spin")}/>
            Refresh
          </Button>
          <Button asChild variant="ghost" size="sm" className="gap-1">
            <Link href="/cluster">
              <Server className="h-4 w-4"/>
              Cluster page
            </Link>
          </Button>
        </div>
      </CardHeader>
      <CardContent className="space-y-6 pt-6">
        {podsQuery.isLoading && !podsQuery.data ? <Skeleton className="h-48 w-full"/> : null}
        {podsQuery.isError ? (<p className="text-sm text-danger">Could not reach the Kubernetes API. Check your session and network.</p>) : null}
        {podsQuery.data && !podsQuery.data.configured ? (<p className="text-sm text-muted">
              Kubernetes is not enabled for this server. Set{" "}
              <code className="rounded bg-muted px-1 py-0.5 text-xs">KUBERNETES_ENABLED=true</code> and give the app a kubeconfig. The{" "}
              <Link href="/cluster" className="font-medium text-primary hover:underline">
                Cluster
              </Link>{" "}
              screen lists the same resources with services and deployments.
              {podsQuery.data.error ? (<span className="mt-2 block text-warning">{podsQuery.data.error}</span>) : null}
            </p>) : null}
        {podsQuery.data?.configured && podsQuery.data.error ? (<p className="rounded-lg border border-warning/40 bg-warning/10 px-3 py-2 text-sm text-warning">{podsQuery.data.error}</p>) : null}
        {podsQuery.data?.configured && !podsQuery.data.error ? (<>
              <div className="max-h-[min(24rem,50vh)] overflow-auto rounded-lg border border-border/70">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Namespace</TableHead>
                      <TableHead>Pod</TableHead>
                      <TableHead>Status</TableHead>
                      <TableHead>Health</TableHead>
                      <TableHead>Ready</TableHead>
                      <TableHead className="text-right">Logs</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {sorted.length === 0 ? (<TableRow>
                        <TableCell colSpan={6} className="text-center text-sm text-muted">
                          No pods in this filter.
                        </TableCell>
                      </TableRow>) : (sorted.map((pod) => (<TableRow key={`${pod.namespace}/${pod.name}`}>
                          <TableCell className="font-mono text-xs">{pod.namespace}</TableCell>
                          <TableCell className="font-mono text-xs">{pod.name}</TableCell>
                          <TableCell>
                            <Badge variant={podStatusBadgeVariant(pod.status)}>{pod.status}</Badge>
                          </TableCell>
                          <TableCell>
                            <Badge variant={podHealthBadgeVariant(pod.health)}>{pod.health}</Badge>
                          </TableCell>
                          <TableCell className="text-xs text-muted">{pod.ready}</TableCell>
                          <TableCell className="text-right">
                            <Button type="button" variant="outline" size="sm" className="gap-1" onClick={() => openLogs(pod)}>
                              <FileText className="h-3.5 w-3.5"/>
                              View
                            </Button>
                          </TableCell>
                        </TableRow>)))}
                  </TableBody>
                </Table>
              </div>
              <div className="space-y-3 rounded-lg border border-border/70 bg-muted/10 p-4">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <p className="text-xs font-semibold uppercase tracking-wide text-muted">Pod logs</p>
                  {selected ? (<div className="flex flex-wrap items-center gap-2">
                      <Badge variant="outline" className="max-w-[min(100%,20rem)] truncate font-mono text-xs">
                        {selected.namespace}/{selected.name}
                      </Badge>
                      {selected.containers.length > 0 ? (<select aria-label="Container" value={selected.container} onChange={(event) => setSelected({
                            ...selected,
                            container: event.target.value
                        })} className="h-8 max-w-[12rem] rounded-md border border-border bg-background px-2 text-xs">
                          {selected.containers.map((c) => <option key={c} value={c}>
                              {c}
                            </option>)}
                        </select>) : null}
                      <Button type="button" variant="outline" size="sm" aria-label="Refresh pod logs" onClick={() => void podLogsQuery.refetch()} disabled={podLogsQuery.isFetching}>
                        {podLogsQuery.isFetching ? <Loader2 className="h-3.5 w-3.5 animate-spin"/> : <RefreshCcw className="h-3.5 w-3.5"/>}
                      </Button>
                    </div>) : null}
                </div>
                <Textarea readOnly value={logBody} className="min-h-[220px] font-mono text-xs"/>
              </div>
            </>) : null}
      </CardContent>
    </Card>);
}
