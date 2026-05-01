"use client";
import { useQuery } from "@tanstack/react-query";
import { CheckCircle2, ExternalLink, Loader2 } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { platformApi } from "@/lib/api";
import type { PlatformIntegrationCategory, PlatformIntegrationItem, PlatformIntegrationReachability, PlatformToolGroup, PlatformToolTone } from "@/types";
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
    return null;
}
function hasLiveUrl(item: PlatformIntegrationItem): boolean {
    return item.kind === "external" && item.configured && Boolean(item.href) && item.reachability?.state === "reachable";
}
function visibleCategories(categories: PlatformIntegrationCategory[]): PlatformIntegrationCategory[] {
    return categories
        .map((category) => ({
        ...category,
        items: category.items.filter(hasLiveUrl)
    }))
        .filter((category) => category.items.length > 0);
}
function IntegrationRow({ item }: {
    item: PlatformIntegrationItem;
}) {
    return (<div className="flex flex-col gap-3 border-b border-border/50 py-4 last:border-b-0 sm:flex-row sm:items-center sm:justify-between">
      <div className="min-w-0">
        <div className="flex flex-wrap items-center gap-2">
          <p className="font-medium text-foreground">{item.name}</p>
          <ReachabilityBadge r={item.reachability}/>
        </div>
      </div>
      <div className="flex shrink-0 flex-wrap gap-2">
        <Button variant="outline" size="sm" asChild>
            <a href={item.href!} target="_blank" rel="noreferrer">
              <ExternalLink className="mr-2 h-4 w-4"/>
              Open
            </a>
          </Button>
      </div>
    </div>);
}
function toneVariant(tone: PlatformToolTone): "success" | "warning" | "danger" | "outline" {
    return tone;
}
function ToolingGroup({ group }: {
    group: PlatformToolGroup;
}) {
    return (<Card className="rounded-xl border-border/70 shadow-sm">
      <CardHeader className="pb-2">
        <CardTitle className="text-lg">{group.title}</CardTitle>
      </CardHeader>
      <CardContent className="grid gap-3 sm:grid-cols-2">
        {group.items.map((item) => (<div key={`${group.title}-${item.name}`} className="rounded-lg border border-border/70 bg-muted/10 p-3">
            <div className="flex items-center justify-between gap-3">
              <p className="font-medium text-foreground">{item.name}</p>
              <Badge variant={toneVariant(item.tone)} className="text-xs">
                {item.tone === "success" ? "Live" : item.tone === "warning" ? "Degraded" : item.tone === "danger" ? "Down" : "Info"}
              </Badge>
            </div>
            <p className="mt-2 text-xs leading-relaxed text-muted">{item.detail}</p>
          </div>))}
      </CardContent>
    </Card>);
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
    const categories = query.data ? visibleCategories(query.data.categories) : [];
    return (<div className="mx-auto max-w-5xl space-y-10">
      <header className="flex items-center justify-between border-b border-border/60 pb-8">
        <div>
        <p className="text-xs font-medium text-muted">Integrations</p>
        <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Platform hub</h1>
        </div>
        {query.isFetching && query.data ? (<Loader2 className="h-4 w-4 animate-spin text-muted" aria-label="Refreshing"/>) : null}
      </header>

      {query.isError ? (<Card className="rounded-xl border-danger/30 bg-danger/5">
          <CardHeader>
            <CardTitle className="text-base">Could not load integrations</CardTitle>
          </CardHeader>
        </Card>) : null}

      {(query.isLoading && !query.data) || (toolingQuery.isLoading && !toolingQuery.data) ? (<div className="space-y-4">
          {Array.from({ length: 4 }).map((_, i) => (<Skeleton key={i} className="h-40 w-full rounded-xl"/>))}
        </div>) : null}

      {toolingQuery.data?.groups?.length ? (<div className="space-y-6">
          {toolingQuery.data.groups.map((group) => <ToolingGroup key={group.title} group={group}/>)}
        </div>) : null}

      {query.data ? (<>
          {categories.length > 0 ? (<div className="space-y-6">
            {categories.map((cat) => (<Card key={cat.id} className="rounded-xl border-border/70 shadow-sm">
                <CardHeader className="pb-0">
                  <CardTitle className="text-lg">{cat.title}</CardTitle>
                </CardHeader>
                <CardContent className="pt-2">
                  {cat.items.map((item) => (<IntegrationRow key={item.id} item={item}/>))}
                </CardContent>
              </Card>))}
          </div>) : (<Card className="rounded-xl border-border/70 shadow-sm">
              <CardHeader>
                <CardTitle className="text-base">No live integrations configured</CardTitle>
              </CardHeader>
            </Card>)}
        </>) : null}
    </div>);
}
