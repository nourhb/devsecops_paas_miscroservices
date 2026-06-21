"use client";
import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { Activity, AlertCircle, Box, CheckCircle2, ExternalLink, GitBranch, Layers, Loader2, Package, RefreshCw, Server, Shield, Wrench } from "lucide-react";
import { Badge, badgeVariants } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { platformApi } from "@/lib/api";
import { cn } from "@/lib/utils";
import type { PlatformIntegrationsResponse, PlatformIntegrationCategory, PlatformIntegrationItem, PlatformIntegrationReachability, PlatformToolGroup, PlatformToolTone } from "@/types";
function toolingStatusLabel(tone: PlatformToolTone): string {
    if (tone === "success") {
        return "Live";
    }
    if (tone === "warning") {
        return "Degraded";
    }
    if (tone === "danger") {
        return "Down";
    }
    return "Info";
}
function toolingStatusExplanation(tone: PlatformToolTone): string {
    if (tone === "success") {
        return "Live: recent check against env or Kubernetes reported a healthy signal.";
    }
    if (tone === "warning") {
        return "Degraded: partial data or a non-critical issue from the last probe.";
    }
    if (tone === "danger") {
        return "Down: probe failed or the integration is unreachable.";
    }
    return "Info: no live probe for this item (placeholder or not detected). Configure related env vars or cluster components if you need it.";
}
function categoryIcon(id: PlatformIntegrationCategory["id"]) {
    const className = "h-5 w-5 shrink-0 text-primary";
    switch (id) {
        case "control-infra":
            return <Server className={className}/>;
        case "security-policy":
            return <Shield className={className}/>;
        case "monitoring":
            return <Activity className={className}/>;
        case "cicd":
            return <GitBranch className={className}/>;
        case "registry":
            return <Package className={className}/>;
        case "security-scan":
            return <Shield className={className}/>;
        case "infra":
            return <Layers className={className}/>;
        default:
            return <Box className={className}/>;
    }
}
function ReachabilityBadge({ r }: {
    r?: PlatformIntegrationReachability;
}) {
    if (!r) {
        return null;
    }
    if (r.state === "reachable") {
        return (<Badge variant="success" className="gap-1 text-xs">
            <CheckCircle2 className="h-3 w-3"/>
            Live{r.latencyMs !== undefined ? ` ${r.latencyMs}ms` : ""}
          </Badge>);
    }
    if (r.state === "unreachable") {
        return (<Badge variant="danger" className="max-w-[14rem] gap-1 truncate text-xs" title={r.message}>
            Unreachable
          </Badge>);
    }
    if (r.state === "skipped") {
        const m = (r.message ?? "").toLowerCase();
        const label = m.includes("argocd") && m.includes("token") ? "Needs Argo token" : m.includes("token") ? "Needs token" : "Skipped";
        return (<Badge variant="outline" className="max-w-[14rem] gap-1 truncate text-xs" title={r.message}>
            {label}
          </Badge>);
    }
    return (<Badge variant="outline" className="text-xs">
        Not checked
      </Badge>);
}
function itemSortRank(item: PlatformIntegrationItem): number {
    if (item.reachability?.state === "reachable") {
        return 0;
    }
    if (item.configured) {
        return 1;
    }
    if (item.optional) {
        return 3;
    }
    return 2;
}
function sortedCategoryItems(items: PlatformIntegrationItem[]): PlatformIntegrationItem[] {
    return [...items].sort((a, b) => itemSortRank(a) - itemSortRank(b) || a.name.localeCompare(b.name));
}
function IntegrationItemRow({ item }: {
    item: PlatformIntegrationItem;
}) {
    const canOpenExternal = item.kind === "external" && Boolean(item.href?.trim());
    const showReachability = item.kind === "external" && item.configured;
    return (<div className="flex flex-col gap-3 border-b border-border/40 py-4 last:border-b-0 sm:flex-row sm:items-start sm:justify-between sm:gap-6">
      <div className="min-w-0 flex-1 space-y-1.5">
        <div className="flex flex-wrap items-center gap-2">
          <p className="font-medium text-foreground">{item.name}</p>
          {!item.configured ? (item.optional ? (<Badge variant="outline" className="text-xs text-muted-foreground">
              Optional
            </Badge>) : (<Badge variant="outline" className="text-xs text-muted-foreground">
              Not configured
            </Badge>)) : item.kind === "internal" ? (<Badge variant="outline" className="border-primary/40 bg-primary/5 text-xs text-foreground">
              In this app
            </Badge>) : null}
          {showReachability ? <ReachabilityBadge r={item.reachability}/> : null}
        </div>
        {item.reachability?.state === "unreachable" && item.reachability.message ? (<p className="text-xs text-danger">
            {item.reachability.message}
          </p>) : null}
        {item.reachability?.state === "skipped" && item.reachability.message ? (<p className="text-xs text-danger/80">{item.reachability.message}</p>) : null}
      </div>
      <div className="flex shrink-0 flex-wrap items-center gap-2 sm:justify-end">
        {item.internalPath ? (<Button variant="default" size="sm" asChild>
            <Link href={item.internalPath}>
              Open
            </Link>
          </Button>) : null}
        {canOpenExternal ? (<Button variant="outline" size="sm" asChild>
            <a href={item.href!} target="_blank" rel="noreferrer">
              <ExternalLink className="mr-2 h-4 w-4"/>
              Open tool
            </a>
          </Button>) : null}
      </div>
    </div>);
}
function CategoryCard({ category }: {
    category: PlatformIntegrationCategory;
}) {
    const items = sortedCategoryItems(category.items);
    const ready = items.filter((i) => i.configured || Boolean(i.optional)).length;
    return (<Card className="rounded-2xl border-border/60 shadow-sm">
      <CardHeader className="border-b border-border/40 pb-4">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div className="flex gap-3">
            <div className="mt-0.5 flex h-10 w-10 items-center justify-center rounded-xl bg-primary/10">
              {categoryIcon(category.id)}
            </div>
            <div className="space-y-1">
              <CardTitle className="flex flex-wrap items-center gap-2 text-lg leading-tight">
                {category.title}
              </CardTitle>
            </div>
          </div>
          <Badge variant="outline" className="w-fit shrink-0 text-xs font-normal">
            {ready}/{items.length} wired
          </Badge>
        </div>
      </CardHeader>
      <CardContent className="pt-1">
        {items.map((item) => <IntegrationItemRow key={item.id} item={item}/>)}
      </CardContent>
    </Card>);
}
function toneVariant(tone: PlatformToolTone): "success" | "warning" | "danger" | "outline" {
    return tone;
}
function toolingAccent(tone: PlatformToolTone): string {
    if (tone === "success") {
        return "border-l-success";
    }
    if (tone === "warning") {
        return "border-l-warning";
    }
    if (tone === "danger") {
        return "border-l-danger";
    }
    return "border-l-muted-foreground/40";
}
function ToolingGroup({ group }: {
    group: PlatformToolGroup;
}) {
    return (<Card className="rounded-2xl border-border/60 shadow-sm">
      <CardHeader className="pb-3">
        <div className="flex items-center gap-2">
          <Wrench className="h-4 w-4 text-muted-foreground"/>
          <CardTitle className="flex flex-wrap items-center gap-2 text-base font-semibold">
            {group.title}
          </CardTitle>
        </div>
        <CardDescription className="text-xs sm:text-sm">
          Signals from env vars and, when enabled, your Kubernetes cluster. “Live” means we see a healthy signal; “Info” means no live probe yet. Hover a status pill for a short explanation — they are indicators, not buttons.
        </CardDescription>
      </CardHeader>
      <CardContent className="grid gap-3 sm:grid-cols-2">
        {group.items.map((item) => (<div key={`${group.title}-${item.name}`} className={cn("rounded-xl border border-border/60 bg-muted/5 p-3.5 border-l-4 pl-4", toolingAccent(item.tone))}>
            <div className="flex items-center justify-between gap-3">
              <p className="font-medium leading-snug text-foreground">{item.name}</p>
              <span title={toolingStatusExplanation(item.tone)} role="status" aria-label={toolingStatusExplanation(item.tone)} className={cn(badgeVariants({
                variant: toneVariant(item.tone)
            }), "shrink-0 cursor-help select-none")}>
                {toolingStatusLabel(item.tone)}
              </span>
            </div>
          </div>))}
      </CardContent>
    </Card>);
}
function DeployReadinessSummary({ dr }: {
    dr: PlatformIntegrationsResponse["meta"]["deployReadiness"];
}) {
    const rows: {
        label: string;
        ok: boolean;
        hint: string;
    }[] = [
        {
            label: dr.buildBackend.selected === "tekton" ? "Tekton" : "Jenkins",
            ok: dr.buildBackend.configured,
            hint: dr.buildBackend.selected === "tekton" ? "Cluster + Tekton namespace" : "Jenkins URL and API token"
        },
        {
            label: "GitOps repo",
            ok: dr.gitops.configured,
            hint: "GITOPS_REPO_URL and token"
        },
        {
            label: "Argo CD",
            ok: dr.argocd.configured,
            hint: "ARGOCD_BASE_URL and auth token or password"
        },
        {
            label: "Public app URLs",
            ok: dr.appsPublicUrl.configured,
            hint: "APPS_PUBLIC_BASE_DOMAIN or URL template"
        }
    ];
    const missing = dr.missingForFullPipeline ?? [];
    return (<Card className="rounded-2xl border-primary/25 bg-primary/[0.06] shadow-sm">
      <CardHeader className="pb-2">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <CardTitle className="flex flex-wrap items-center gap-2 text-base">
              <AlertCircle className="h-4 w-4 text-primary"/>
              Delivery checklist
            </CardTitle>
            <CardDescription className="mt-1 max-w-2xl text-sm">
              What the platform needs to run builds, push to GitOps, sync Argo CD, and expose app URLs. Fix the red items in your server environment, then refresh.
            </CardDescription>
          </div>
          {dr.simulationEnabled ? (<Badge variant="warning" className="shrink-0">
              Simulation on
            </Badge>) : null}
        </div>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="grid gap-2 sm:grid-cols-2">
          {rows.map((row) => (<div key={row.label} className={cn("flex items-center justify-between gap-3 rounded-lg border px-3 py-2.5 text-sm", row.ok ? "border-success/30 bg-success/5" : "border-border bg-card")}>
              <span className="font-medium text-foreground">{row.label}</span>
              {row.ok ? (<span className="flex items-center gap-1 text-xs text-success">
                  <CheckCircle2 className="h-3.5 w-3.5"/>
                  Ready
                </span>) : (<span className="text-xs text-muted">—</span>)}
            </div>))}
        </div>
        {missing.length > 0 ? (<div className="rounded-xl border border-warning/40 bg-warning/5 p-4">
            <p className="text-sm font-medium text-foreground">Still needed for a full pipeline</p>
            <ul className="mt-2 list-inside list-disc space-y-1 text-sm leading-relaxed text-foreground/90">
              {missing.map((line: string) => <li key={line}>{line}</li>)}
            </ul>
          </div>) : (<p className="flex items-center gap-2 text-sm text-success">
            <CheckCircle2 className="h-4 w-4 shrink-0"/>
            Core pipeline settings look complete. External tools below can still be added.
          </p>)}
      </CardContent>
    </Card>);
}
function MetaStrip({ meta }: {
    meta: PlatformIntegrationsResponse["meta"];
}) {
    const chips: {
        label: string;
        active: boolean;
    }[] = [
        { label: "Kubernetes API", active: meta.kubernetesEnabled },
        { label: `Build: ${meta.buildBackend}`, active: true },
        { label: `Policy: ${meta.policyEngine || "—"}`, active: true },
        { label: "Harbor", active: meta.harborConfigured }
    ];
    return (<div className="flex flex-wrap gap-2">
      {chips.map((c) => (<Badge key={c.label} variant={c.active ? "default" : "outline"} className={cn("font-normal", !c.active && "text-muted-foreground")}>
          {c.label}
          {c.active ? "" : " · off"}
        </Badge>))}
    </div>);
}
export default function IntegrationsPage() {
    const query = useQuery({
        queryKey: ["platform-integrations"],
        queryFn: platformApi.getIntegrations,
        staleTime: 30000,
        refetchInterval: 60000
    });
    const toolingQuery = useQuery({
        queryKey: ["platform-tooling"],
        queryFn: platformApi.getTooling,
        staleTime: 30000,
        refetchInterval: 60000
    });
    const isLoading = (query.isLoading && !query.data) || (toolingQuery.isLoading && !toolingQuery.data);
    const isRefreshing = query.isFetching || toolingQuery.isFetching;
    function refreshAll() {
        void query.refetch();
        void toolingQuery.refetch();
    }
    const meta = query.data?.meta;
    const categories = query.data?.categories ?? [];
    return (<div className="mx-auto max-w-6xl space-y-10 px-1 sm:px-0">
      <header className="flex flex-col gap-6 border-b border-border/60 pb-8">
        <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
          <div className="space-y-3">
            <p className="text-xs font-semibold uppercase tracking-wider text-muted">Integrations</p>
            <h1 className="flex flex-wrap items-center gap-2 text-3xl font-semibold tracking-tight text-foreground sm:text-4xl">
              Platform hub
            </h1>
            {meta ? <MetaStrip meta={meta}/> : null}
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <Button type="button" variant="outline" size="sm" className="gap-2 shadow-sm" onClick={() => refreshAll()} disabled={isRefreshing}>
              {isRefreshing ? <Loader2 className="h-4 w-4 animate-spin"/> : <RefreshCw className="h-4 w-4"/>}
              Refresh
            </Button>
            <Button type="button" variant="ghost" size="sm" asChild>
              <Link href="/dashboard">Dashboard</Link>
            </Button>
          </div>
        </div>
      </header>

      {query.isError ? (<Card className="rounded-2xl border-danger/40 bg-danger/5">
          <CardHeader>
            <CardTitle className="text-base flex flex-wrap items-center gap-2">
              Could not load integrations
            </CardTitle>
            <CardDescription>Check your session and try Refresh. If this persists, verify the API route and server logs.</CardDescription>
          </CardHeader>
        </Card>) : null}

      {isLoading ? (<div className="space-y-4">
          {Array.from({ length: 5 }).map((_, i) => (<Skeleton key={i} className="h-44 w-full rounded-2xl"/>))}
        </div>) : null}

      {!isLoading && query.data?.meta?.deployReadiness ? (<DeployReadinessSummary dr={query.data.meta.deployReadiness}/>) : null}

      {toolingQuery.data?.groups?.length ? (<section className="space-y-4">
          <div className="flex items-end justify-between gap-4">
            <div>
              <h2 className="text-lg font-semibold text-foreground flex flex-wrap items-center gap-2">
              Runtime signals
            </h2>
            </div>
          </div>
          <div className="space-y-6">
            {toolingQuery.data.groups.map((group) => <ToolingGroup key={group.title} group={group}/>)}
          </div>
        </section>) : null}

      {query.data && categories.length > 0 ? (<section className="space-y-4">
          <div>
            <h2 className="text-lg font-semibold text-foreground flex flex-wrap items-center gap-2">
              Integration catalog
            </h2>
          </div>
          <div className="space-y-6">
            {categories.map((category) => <CategoryCard key={category.id} category={category}/>)}
          </div>
        </section>) : null}

      {query.data && categories.length === 0 ? (<Card className="rounded-2xl border-border/70 shadow-sm">
          <CardHeader>
            <CardTitle className="text-base flex flex-wrap items-center gap-2">
              No integration categories
            </CardTitle>
            <CardDescription>Something returned an empty catalog. Check server logs and redeploy the frontend.</CardDescription>
          </CardHeader>
        </Card>) : null}
    </div>);
}
