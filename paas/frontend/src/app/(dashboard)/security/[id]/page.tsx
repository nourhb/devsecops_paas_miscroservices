"use client";
import { useParams } from "next/navigation";
import { useQuery } from "@tanstack/react-query";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Progress } from "@/components/ui/progress";
import { Skeleton } from "@/components/ui/skeleton";
import { securityApi } from "@/lib/api";
const SEVERITY_ROWS = [
    { key: "critical", label: "Critical", dotClassName: "bg-danger" },
    { key: "high", label: "High", dotClassName: "bg-orange-500" },
    { key: "medium", label: "Medium", dotClassName: "bg-yellow-500" },
    { key: "low", label: "Low", dotClassName: "bg-success" }
] as const;
export default function SecurityPage() {
    const params = useParams<{
        id: string;
    }>();
    const projectId = params.id;
    const securityQuery = useQuery({
        queryKey: ["security", projectId],
        queryFn: () => securityApi.getSecurity(projectId)
    });
    const data = securityQuery.data;
    if (securityQuery.isLoading) {
        return (<div className="space-y-6">
      <Skeleton className="h-8 w-80"/>
      <Skeleton className="h-24 w-full"/>
      <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        <Skeleton className="h-64"/>
        <Skeleton className="h-64"/>
        <Skeleton className="h-64"/>
      </section>
    </div>);
    }
    if (securityQuery.isError || !data) {
        return (<Card className="border-danger/30">
      <CardHeader>
        <CardTitle>Security data unavailable</CardTitle>
      </CardHeader>
      <CardContent className="text-sm text-muted">
        Could not load Trivy, SonarQube, Dependency-Track, Cosign, or policy gate data for this project.
      </CardContent>
    </Card>);
    }
    return (<div className="space-y-6">
      <div className="flex items-center justify-between">
        <h2 className="text-2xl font-semibold">Security Overview: {projectId}</h2>
        <Badge variant={data.qualityGateStatus === "PASSED" ? "success" : data.qualityGateStatus === "UNKNOWN" ? "outline" : "danger"}>
          Sonar Quality Gate: {data.qualityGateStatus}
        </Badge>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Global Security Score</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="space-y-2">
            <Progress value={data.securityScore}/>
            <p className="text-sm text-muted">{data.securityScore}/100</p>
          </div>
        </CardContent>
      </Card>

      <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        <Card>
          <CardHeader>
            <CardTitle>Security Analysis</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4 text-sm">
            <div className="rounded-lg border border-border bg-muted/20 p-3 text-muted">
              <p className="font-medium text-foreground">{data.securitySummary}</p>
              {data?.dependencyTrackProjectUuid ? <p className="mt-2 font-mono text-xs">Project UUID: {data.dependencyTrackProjectUuid}</p> : null}
            </div>
            <div className="overflow-hidden rounded-lg border border-border">
              <table className="w-full text-left text-sm">
                <thead className="bg-muted/30 text-muted">
                  <tr>
                    <th className="px-3 py-2 font-medium">Severity</th>
                    <th className="px-3 py-2 font-medium">Count</th>
                  </tr>
                </thead>
                <tbody>
                  {SEVERITY_ROWS.map((row) => <tr key={row.key} className="border-t border-border">
                      <td className="px-3 py-2">
                        <span className="inline-flex items-center gap-2">
                          <span className={`h-2.5 w-2.5 rounded-full ${row.dotClassName}`}/>
                          <span>{row.label}</span>
                        </span>
                      </td>
                      <td className="px-3 py-2 font-semibold text-foreground">
                        {data?.dependencyTrack[row.key] ?? 0}
                      </td>
                    </tr>)}
                </tbody>
              </table>
            </div>
            {data?.dependencyTrackFindings?.length ? <div className="space-y-2">
                {data.dependencyTrackFindings.map((finding, index) => <div key={`${finding.vulnerabilityId || finding.title}-${index}`} className="rounded-lg border border-border/80 bg-background/50 p-3">
                    <p className="font-medium text-foreground">
                      {finding.severity} · {finding.title}
                    </p>
                    {finding.component ? <p className="mt-1 text-xs text-muted">Component: {finding.component}</p> : null}
                    {finding.recommendation ? <p className="mt-2 text-sm text-muted">
                        AI hint: {finding.recommendation}
                      </p> : null}
                  </div>)}
              </div> : null}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Trivy Scan</CardTitle>
          </CardHeader>
          <CardContent className="space-y-1 text-sm">
            <p>Critical: {data?.trivy.critical ?? 0}</p>
            <p>High: {data?.trivy.high ?? 0}</p>
            <p>Medium: {data?.trivy.medium ?? 0}</p>
            <p>Low: {data?.trivy.low ?? 0}</p>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Security Enforcement</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4 text-sm">
            <div className="space-y-2">
              <div className="flex items-center justify-between rounded-lg border border-border px-3 py-2">
                <span className="text-muted">Image signed</span>
                <Badge variant={data?.imageSecurity?.signed ? "success" : "danger"}>
                  {data?.imageSecurity?.signed ? "Verified" : "Missing signature"}
                </Badge>
              </div>
              <div className="flex items-center justify-between rounded-lg border border-border px-3 py-2">
                <span className="text-muted">Policy validated</span>
                <Badge variant={data?.securityEnforcement?.policyValidated ? "success" : "warning"}>
                  {data?.securityEnforcement?.policyValidated ? "Passed" : "Blocked"}
                </Badge>
              </div>
              <div className="flex items-center justify-between rounded-lg border border-border px-3 py-2">
                <span className="text-muted">Deployment allowed</span>
                <Badge variant={data?.securityEnforcement?.deploymentAllowed ? "success" : "danger"}>
                  {data?.securityEnforcement?.deploymentAllowed ? "Allowed" : "Denied"}
                </Badge>
              </div>
            </div>
            <div className="rounded-lg border border-border bg-muted/20 p-3">
              <p className="text-xs uppercase tracking-wide text-muted">
                Policy engine: {data?.securityEnforcement?.policyEngine ?? "Kyverno"}
              </p>
              <p className="mt-2 text-sm text-foreground">
                {data?.securityEnforcement?.summary ?? "Security enforcement data is loading."}
              </p>
              {data?.imageSecurity?.imageRef ? <p className="mt-2 break-all font-mono text-xs text-muted">
                  {data.imageSecurity.imageRef}
                </p> : null}
            </div>
          </CardContent>
        </Card>
      </section>
    </div>);
}
