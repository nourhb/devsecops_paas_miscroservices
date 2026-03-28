"use client";

import { useParams } from "next/navigation";
import { useTheme } from "next-themes";
import { useQuery } from "@tanstack/react-query";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { metricsApi, pipelineApi } from "@/lib/api";

export default function MonitoringPage() {
  const params = useParams<{ id: string }>();
  const projectId = params.id;
  const { resolvedTheme } = useTheme();

  const metricsQuery = useQuery({
    queryKey: ["metrics", projectId],
    queryFn: () => metricsApi.getMetrics(projectId)
  });

  const statusQuery = useQuery({
    queryKey: ["status", projectId],
    queryFn: () => pipelineApi.getStatus(projectId)
  });

  const grafanaBaseUrl = process.env.NEXT_PUBLIC_GRAFANA_URL || "http://localhost:3001";
  const grafanaTheme = resolvedTheme === "light" ? "light" : "dark";
  const iframeUrl = `${grafanaBaseUrl}/d-solo/paas-overview/devsecops-overview?orgId=1&theme=${grafanaTheme}&var-project=${encodeURIComponent(projectId)}`;

  return (
    <div className="space-y-6">
      <h2 className="text-2xl font-semibold">Monitoring: {projectId}</h2>

      <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
        <Card>
          <CardHeader>
            <CardTitle className="text-sm">CPU Usage</CardTitle>
          </CardHeader>
          <CardContent className="text-2xl font-semibold">
            {metricsQuery.isLoading ? <Skeleton className="h-8 w-16" /> : `${metricsQuery.data?.cpuUsagePercent ?? 0}%`}
          </CardContent>
        </Card>
        <Card>
          <CardHeader><CardTitle className="text-sm">Memory Usage</CardTitle></CardHeader>
          <CardContent className="text-2xl font-semibold">{metricsQuery.data?.memoryUsagePercent ?? 0}%</CardContent>
        </Card>
        <Card>
          <CardHeader><CardTitle className="text-sm">Pod Health</CardTitle></CardHeader>
          <CardContent className="text-2xl font-semibold">{statusQuery.data?.podStatus ?? "n/a"}</CardContent>
        </Card>
        <Card>
          <CardHeader><CardTitle className="text-sm">Namespace</CardTitle></CardHeader>
          <CardContent className="text-2xl font-semibold">{statusQuery.data?.namespace ?? "n/a"}</CardContent>
        </Card>
      </section>

      <Card>
        <CardHeader>
          <CardTitle>Grafana Dashboard (Embedded)</CardTitle>
        </CardHeader>
        <CardContent>
          <iframe
            src={iframeUrl}
            title="Grafana dashboard"
            className="h-[520px] w-full rounded-md border border-border"
            loading="lazy"
          />
        </CardContent>
      </Card>
    </div>
  );
}
