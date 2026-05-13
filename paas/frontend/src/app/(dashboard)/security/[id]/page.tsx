"use client";
import { useParams } from "next/navigation";
import { useQuery } from "@tanstack/react-query";
import { Bar, BarChart, CartesianGrid, Cell, Legend, Pie, PieChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Progress } from "@/components/ui/progress";
import { Skeleton } from "@/components/ui/skeleton";
import { Hint } from "@/components/hint";
import { securityApi } from "@/lib/api";
import { hints } from "@/lib/app-hints";
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
        <h2 className="flex flex-wrap items-center gap-2 text-2xl font-semibold">
          Security Overview: {projectId}
          <Hint side="bottom">{hints.security.overviewTitle}</Hint>
        </h2>
        <Badge variant={data.qualityGateStatus === "PASSED" ? "success" : data.qualityGateStatus === "UNKNOWN" ? "outline" : "danger"}>
          Sonar Quality Gate: {data.qualityGateStatus}
        </Badge>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="flex flex-wrap items-center gap-2">
            Global Security Score
            <Hint>{hints.security.globalScore}</Hint>
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
              <Hint>{hints.security.sonarGate}</Hint>
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="h-[180px]">
              <ResponsiveContainer width="100%" height="100%">
                <PieChart>
                  <Pie data={[
            {
                name: `Gate: ${data.qualityGateStatus}`,
                value: 1
            }
        ]} dataKey="value" nameKey="name" cx="50%" cy="50%" innerRadius={52} outerRadius={72}>
                    <Cell fill={data.qualityGateStatus === "PASSED"
            ? "#22c55e"
            : data.qualityGateStatus === "UNKNOWN" ? "#64748b" : "#ef4444"}/>
                  </Pie>
                  <Tooltip contentStyle={{ background: "hsl(var(--card))", border: "1px solid hsl(var(--border))", borderRadius: 12 }}/>
                </PieChart>
              </ResponsiveContainer>
            </div>
            <p className="text-center text-xs text-muted">Value comes from SonarQube quality-gate API for this project key.</p>
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="flex flex-wrap items-center gap-2">
              Dependency-Track vs Trivy (severity counts)
              <Hint>{hints.security.depTrackVsTrivy}</Hint>
            </CardTitle>
          </CardHeader>
          <CardContent className="h-[220px]">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={[
            {
                severity: "Critical",
                dt: data.dependencyTrack.critical,
                trivy: data.trivy.critical
            },
            {
                severity: "High",
                dt: data.dependencyTrack.high,
                trivy: data.trivy.high
            },
            {
                severity: "Medium",
                dt: data.dependencyTrack.medium,
                trivy: data.trivy.medium
            },
            {
                severity: "Low",
                dt: data.dependencyTrack.low,
                trivy: data.trivy.low
            }
        ]} margin={{ top: 8, right: 8, left: 8, bottom: 4 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="hsl(var(--border))" vertical={false}/>
                <XAxis dataKey="severity" tick={{ fontSize: 11, fill: "hsl(var(--muted-foreground))" }} tickLine={false} axisLine={false}/>
                <YAxis allowDecimals={false} tick={{ fontSize: 11, fill: "hsl(var(--muted-foreground))" }} tickLine={false} axisLine={false}/>
                <Tooltip contentStyle={{ background: "hsl(var(--card))", border: "1px solid hsl(var(--border))", borderRadius: 12 }}/>
                <Legend wrapperStyle={{ fontSize: 12 }}/>
                <Bar dataKey="dt" name="Dependency-Track" fill="#0ea5e9" radius={[6, 6, 0, 0]}/>
                <Bar dataKey="trivy" name="Trivy" fill="#f97316" radius={[6, 6, 0, 0]}/>
              </BarChart>
            </ResponsiveContainer>
          </CardContent>
        </Card>
        <Card className="xl:col-span-2">
          <CardHeader>
            <CardTitle className="flex flex-wrap items-center gap-2">
              Cosign, OPA, Kyverno / policy engine signals
              <Hint>{hints.security.policySignals}</Hint>
            </CardTitle>
          </CardHeader>
          <CardContent className="h-[200px]">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart layout="vertical" data={[
            {
                name: "Cosign signed",
                v: data.cosignSigned ? 1 : 0,
                fill: data.cosignSigned ? "#22c55e" : "#ef4444"
            },
            {
                name: "Policy validated",
                v: data.securityEnforcement?.policyValidated ? 1 : 0,
                fill: data.securityEnforcement?.policyValidated ? "#22c55e" : "#eab308"
            },
            {
                name: "Deploy allowed",
                v: data.securityEnforcement?.deploymentAllowed ? 1 : 0,
                fill: data.securityEnforcement?.deploymentAllowed ? "#22c55e" : "#ef4444"
            },
            {
                name: "OPA violations",
                v: data.opaViolations,
                fill: "#f97316"
            }
        ]} margin={{ left: 16, right: 16, top: 8, bottom: 8 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="hsl(var(--border))" horizontal={false}/>
                <XAxis type="number" allowDecimals={false} tickLine={false} axisLine={false}/>
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
            <Hint>{hints.security.analysisCard}</Hint>
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
            <Hint>{hints.security.trivyCard}</Hint>
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
            <Hint>{hints.security.enforcementCard}</Hint>
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
