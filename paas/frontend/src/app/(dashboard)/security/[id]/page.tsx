"use client";
import Link from "next/link";
import { useParams } from "next/navigation";
import { useQuery } from "@tanstack/react-query";
import { Bar, BarChart, CartesianGrid, Cell, Legend, Pie, PieChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Progress } from "@/components/ui/progress";
import { Skeleton } from "@/components/ui/skeleton";
import { ChartCaption, ChartStatRow } from "@/components/charts/chart-stat-row";
import { CHART_COLORS, chartYDomain, pieRowsForDisplay, sumSeverityCounts } from "@/components/charts/chart-display-utils";
import { PipelineVerificationPanel } from "@/components/pipeline/pipeline-verification-panel";
import { projectApi, securityApi } from "@/lib/api";
import { queryHttpMessage } from "@/lib/query-http-message";
import type { SecurityIntegrationProbeStatus } from "@/types";
const SEVERITY_ROWS = [
    { key: "critical", label: "Critical", dotClassName: "bg-danger" },
    { key: "high", label: "High", dotClassName: "bg-orange-500" },
    { key: "medium", label: "Medium", dotClassName: "bg-yellow-500" },
    { key: "low", label: "Low", dotClassName: "bg-success" }
] as const;
function probeBadgeVariant(status: SecurityIntegrationProbeStatus): "success" | "danger" | "warning" | "outline" {
    if (status === "OK") {
        return "success";
    }
    if (status === "FAIL") {
        return "danger";
    }
    if (status === "WARN") {
        return "warning";
    }
    return "outline";
}
function sonarGateColor(status: string): string {
    if (status === "PASSED") {
        return CHART_COLORS.success;
    }
    if (status === "FAILED") {
        return CHART_COLORS.danger;
    }
    if (status === "SKIPPED") {
        return CHART_COLORS.warning;
    }
    return CHART_COLORS.muted;
}
function severityChartData(dt: {
    critical: number;
    high: number;
    medium: number;
    low: number;
}, trivy: {
    critical: number;
    high: number;
    medium: number;
    low: number;
}) {
    return [
        { severity: "Critical", dt: dt.critical, trivy: trivy.critical },
        { severity: "High", dt: dt.high, trivy: trivy.high },
        { severity: "Medium", dt: dt.medium, trivy: trivy.medium },
        { severity: "Low", dt: dt.low, trivy: trivy.low }
    ];
}
export default function SecurityPage() {
    const params = useParams<{
        id: string;
    }>();
    const projectId = params.id;
    const projectQuery = useQuery({
        queryKey: ["project", projectId],
        queryFn: () => projectApi.getProject(projectId)
    });
    const securityQuery = useQuery({
        queryKey: ["security", projectId],
        queryFn: () => securityApi.getSecurity(projectId),
        retry: 1,
        staleTime: 5000,
        refetchInterval: projectQuery.data?.buildStatus === "BUILDING" || ["DEPLOYING", "PROMOTING"].includes((projectQuery.data?.lastDeploymentStatus || "").toUpperCase())
            ? 5000
            : 20000
    });
    const displayName = projectQuery.data?.projectName ?? projectId;
    const data = securityQuery.data;
    const severityTotals = data
        ? data.dependencyTrack.critical +
          data.dependencyTrack.high +
          data.dependencyTrack.medium +
          data.dependencyTrack.low +
          data.trivy.critical +
          data.trivy.high +
          data.trivy.medium +
          data.trivy.low
        : 0;
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
        const errMsg = securityQuery.isError
            ? queryHttpMessage(securityQuery.error, "Could not load security data (integrations may be slow or misconfigured).")
            : "No security payload returned.";
        return (<div className="space-y-4">
      <Card className="border-danger/30">
        <CardHeader>
          <CardTitle>Security data unavailable</CardTitle>
          <CardDescription>{errMsg}</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-wrap gap-2 text-sm">
          <Button variant="outline" size="sm" onClick={() => securityQuery.refetch()}>
            Retry
          </Button>
          <Button asChild variant="outline" size="sm">
            <Link href={`/pipeline/${projectId}`}>Open pipeline &amp; Jenkins logs</Link>
          </Button>
        </CardContent>
      </Card>
    </div>);
    }
    const dtTotal = sumSeverityCounts(data.dependencyTrack);
    const trivyTotal = sumSeverityCounts(data.trivy);
    const sonarPieData = pieRowsForDisplay([
        { name: `Gate: ${data.qualityGateStatus}`, value: 1, fill: sonarGateColor(data.qualityGateStatus) }
    ], `Gate: ${data.qualityGateStatus}`);
    const pipeline = data.pipelineVerification;
    const buildCtx = data.buildContext;
    const deployFailed = (buildCtx?.deploymentStatus || "").toUpperCase() === "FAILED";
    return (<div className="space-y-6">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <h2 className="flex flex-wrap items-center gap-2 text-2xl font-semibold">
          Security Overview: {displayName}
        </h2>
        <div className="flex flex-wrap items-center gap-2">
          <Badge variant={data.qualityGateStatus === "PASSED"
            ? "success"
            : data.qualityGateStatus === "UNKNOWN" || data.qualityGateStatus === "SKIPPED"
                ? "outline"
                : "danger"}>
            Sonar Quality Gate: {data.qualityGateStatus}
          </Badge>
        </div>
      </div>

      {deployFailed ? (<Card className="border-danger/30 bg-danger/5">
        <CardHeader>
          <CardTitle className="text-base">Last deployment failed — security results may still apply</CardTitle>
        </CardHeader>
        <CardContent className="space-y-1 text-sm text-muted">
          <p>
            Status: <span className="font-medium text-foreground">{buildCtx?.deploymentStatus ?? "FAILED"}</span>
            {buildCtx?.jenkinsBuildNumber != null ? ` · Jenkins build #${buildCtx.jenkinsBuildNumber}` : null}
            {buildCtx?.jenkinsBuildResult ? ` · result=${buildCtx.jenkinsBuildResult}` : null}
          </p>
          {buildCtx?.deploymentFailureReason ? <p>Reason: {buildCtx.deploymentFailureReason}</p> : null}
          {buildCtx?.deploymentFailureMessage ? <p className="font-mono text-xs break-all">{buildCtx.deploymentFailureMessage}</p> : null}
        </CardContent>
      </Card>) : null}

      {data.integrationProbes?.length ? (<Card>
        <CardHeader>
          <CardTitle className="text-base">Tool-by-tool status</CardTitle>
          <CardDescription>Live probes plus Jenkins Step 4/5/9 markers from the latest build logs.</CardDescription>
        </CardHeader>
        <CardContent className="overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead className="text-xs uppercase tracking-wide text-muted">
              <tr>
                <th className="pb-2 pr-4 font-medium">Tool</th>
                <th className="pb-2 pr-4 font-medium">Configured</th>
                <th className="pb-2 pr-4 font-medium">Status</th>
                <th className="pb-2 font-medium">Detail</th>
              </tr>
            </thead>
            <tbody>
              {data.integrationProbes.map((probe) => (<tr key={probe.tool} className="border-t border-border">
                  <td className="py-2 pr-4 font-medium">{probe.tool}</td>
                  <td className="py-2 pr-4">{probe.configured ? "Yes" : "No"}</td>
                  <td className="py-2 pr-4">
                    <Badge variant={probeBadgeVariant(probe.status)}>{probe.status}</Badge>
                  </td>
                  <td className="py-2 text-muted">{probe.detail}</td>
                </tr>))}
            </tbody>
          </table>
        </CardContent>
      </Card>) : null}

      <PipelineVerificationPanel jenkinsChecks={pipeline?.jenkinsChecks ?? []} deployChecks={pipeline?.deployChecks ?? []} buildComplete={pipeline?.buildComplete ?? null} artifactImage={pipeline?.artifactImage ?? null}/>

      {data.securityLogExcerpt ? (<Card>
        <CardHeader>
          <CardTitle className="text-base">Security log excerpt</CardTitle>
          <CardDescription>
            Filtered from Jenkins / deployment logs (PAAS_STEP, Sonar, SCA, Cosign, Trivy). Open Pipeline for the full console.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <pre className="max-h-96 overflow-auto rounded-lg border border-border bg-muted/20 p-3 font-mono text-[11px] leading-relaxed whitespace-pre-wrap break-all">
            {data.securityLogExcerpt}
          </pre>
          <div className="mt-3 flex flex-wrap gap-2">
            <Button asChild variant="outline" size="sm">
              <Link href={`/pipeline/${projectId}`}>Full pipeline logs</Link>
            </Button>
          </div>
        </CardContent>
      </Card>) : null}

      <Card className={severityTotals === 0 && data.qualityGateStatus === "UNKNOWN" ? "border-warning/40 bg-warning/5" : undefined}>
        <CardHeader>
          <CardTitle className="text-base">Integration status</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm text-muted">
          <p>{data.securitySummary}</p>
          <p className="font-mono text-xs break-all">Image: {data.imageSecurity?.imageRef ?? "—"}</p>
          {data.dependencyTrackProjectUuid ? (
            <p className="text-xs">Dependency-Track project linked ({data.dependencyTrackProjectName}).</p>
          ) : (
            <p className="text-xs">Dependency-Track: run a full Jenkins deploy (Step 4 SCA) with DEPENDENCY_TRACK_API_KEY — not a GitOps-only fix.</p>
          )}
          {data.qualityGateStatus === "UNKNOWN" ? (
            <p className="text-xs">SonarQube: set a valid SONAR_TOKEN and run Step 5 (disable JENKINS_PAAS_FAST_PIPELINE for full pipeline).</p>
          ) : null}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="flex flex-wrap items-center gap-2">
            Global Security Score
          </CardTitle>
        </CardHeader>
        <CardContent>
          <div className="space-y-2">
            <Progress value={data.securityScore}/>
            <p className="text-sm text-muted">{data.securityScore}/100</p>
          </div>
        </CardContent>
      </Card>

      <section className="grid gap-4 xl:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="flex flex-wrap items-center gap-2">
              SonarQube quality gate (live)
            </CardTitle>
          </CardHeader>
          <CardContent>
            <ChartStatRow items={[
              { label: "Gate status", value: data.qualityGateStatus },
              { label: "Score impact", value: data.qualityGateStatus === "PASSED" ? "OK" : data.qualityGateStatus === "UNKNOWN" ? "Pending" : "Risk" }
            ]}/>
            <div className="h-[180px]">
              <ResponsiveContainer width="100%" height="100%">
                <PieChart>
                  <Pie data={sonarPieData} dataKey="value" nameKey="name" cx="50%" cy="50%" innerRadius={52} outerRadius={72}>
                    {sonarPieData.map((entry) => <Cell key={entry.name} fill={entry.fill}/>)}
                  </Pie>
                  <Tooltip contentStyle={{ background: "hsl(var(--card))", border: "1px solid hsl(var(--border))", borderRadius: 12 }}/>
                  <Legend wrapperStyle={{ fontSize: 12 }}/>
                </PieChart>
              </ResponsiveContainer>
            </div>
            <ChartCaption>
              {data.qualityGateStatus === "UNKNOWN"
                ? "Gate pending — run full deploy with SONAR_HOST_URL + SONAR_TOKEN."
                : data.qualityGateStatus === "SKIPPED"
                    ? "Step 5 skipped (fast pipeline or missing Sonar config)."
                    : "Live quality gate for this project key."}
            </ChartCaption>
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="flex flex-wrap items-center gap-2">
              Dependency-Track vs Trivy (severity counts)
            </CardTitle>
          </CardHeader>
          <CardContent>
            <ChartStatRow items={[
              { label: "DT total", value: dtTotal },
              { label: "Trivy total", value: trivyTotal }
            ]}/>
            <div className="h-[220px]">
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={severityChartData(data.dependencyTrack, data.trivy)} margin={{ top: 8, right: 8, left: 8, bottom: 4 }}>
                  <CartesianGrid strokeDasharray="3 3" stroke="hsl(var(--border))" vertical={false}/>
                  <XAxis dataKey="severity" tick={{ fontSize: 11, fill: "hsl(var(--muted-foreground))" }} tickLine={false} axisLine={false}/>
                  <YAxis allowDecimals={false} domain={chartYDomain([severityTotals])} tick={{ fontSize: 11, fill: "hsl(var(--muted-foreground))" }} tickLine={false} axisLine={false}/>
                  <Tooltip contentStyle={{ background: "hsl(var(--card))", border: "1px solid hsl(var(--border))", borderRadius: 12 }}/>
                  <Legend wrapperStyle={{ fontSize: 12 }}/>
                  <Bar dataKey="dt" name="Dependency-Track" fill="#0ea5e9" radius={[6, 6, 0, 0]}/>
                  <Bar dataKey="trivy" name="Trivy" fill="#f97316" radius={[6, 6, 0, 0]}/>
                </BarChart>
              </ResponsiveContainer>
            </div>
            <ChartCaption>
              {severityTotals === 0
                ? data.dependencyTrackProjectUuid
                    ? "0 findings — linked Dependency-Track project and Trivy scan are clean."
                    : "0 counted — run Step 4 SCA + image scan for live SBOM/Trivy data."
                : `${severityTotals} total findings across both scanners.`}
            </ChartCaption>
          </CardContent>
        </Card>
        <Card className="xl:col-span-2">
          <CardHeader>
            <CardTitle className="flex flex-wrap items-center gap-2">
              Cosign, OPA, Kyverno / policy engine signals
            </CardTitle>
          </CardHeader>
          <CardContent className="h-[200px]">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart layout="vertical" data={[
            {
                name: "Cosign signed",
                v: 1,
                fill: data.cosignSigned ? "#22c55e" : "#ef4444"
            },
            {
                name: "Policy validated",
                v: 1,
                fill: data.securityEnforcement?.policyValidated ? "#22c55e" : "#eab308"
            },
            {
                name: "Deploy allowed",
                v: 1,
                fill: data.securityEnforcement?.deploymentAllowed ? "#22c55e" : "#ef4444"
            },
            {
                name: "OPA violations",
                v: 1,
                fill: data.opaViolations > 0 ? "#f97316" : "#64748b"
            }
        ]} margin={{ left: 16, right: 16, top: 8, bottom: 8 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="hsl(var(--border))" horizontal={false}/>
                <XAxis type="number" allowDecimals={false} domain={[0, 1]} tickLine={false} axisLine={false}/>
                <YAxis type="category" dataKey="name" width={120} tickLine={false} axisLine={false} tick={{ fontSize: 11 }}/>
                <Tooltip contentStyle={{ background: "hsl(var(--card))", border: "1px solid hsl(var(--border))", borderRadius: 12 }}/>
                <Bar dataKey="v" radius={[0, 8, 8, 0]}>
                  {[
            data.cosignSigned ? "#22c55e" : "#ef4444",
            data.securityEnforcement?.policyValidated ? "#22c55e" : "#eab308",
            data.securityEnforcement?.deploymentAllowed ? "#22c55e" : "#ef4444",
            "#f97316"
        ].map((fill, i) => <Cell key={i} fill={fill}/>)}
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          </CardContent>
          <p className="px-6 pb-4 text-xs text-muted">
            Policy engine in use: {data.securityEnforcement?.policyEngine ?? "—"}. Kyverno policy lists are evaluated when the cluster integration and POLICY_ENGINE are set.
          </p>
        </Card>
      </section>

      <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        <Card>
          <CardHeader>
            <CardTitle className="flex flex-wrap items-center gap-2">
            Security Analysis
          </CardTitle>
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
                        Tip: {finding.recommendation}
                      </p> : null}
                  </div>)}
              </div> : null}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex flex-wrap items-center gap-2">
            Trivy Scan
          </CardTitle>
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
            <CardTitle className="flex flex-wrap items-center gap-2">
            Security Enforcement
          </CardTitle>
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
