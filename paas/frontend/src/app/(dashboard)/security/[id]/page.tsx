"use client";

import { useParams } from "next/navigation";
import { useQuery } from "@tanstack/react-query";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Progress } from "@/components/ui/progress";
import { securityApi } from "@/lib/api";

export default function SecurityPage() {
  const params = useParams<{ id: string }>();
  const projectId = params.id;

  const securityQuery = useQuery({
    queryKey: ["security", projectId],
    queryFn: () => securityApi.getSecurity(projectId)
  });

  const data = securityQuery.data;

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h2 className="text-2xl font-semibold">Security Overview: {projectId}</h2>
        <Badge variant={data?.qualityGateStatus === "PASSED" ? "success" : "danger"}>
          Sonar Quality Gate: {data?.qualityGateStatus || "UNKNOWN"}
        </Badge>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Global Security Score</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="space-y-2">
            <Progress value={data?.securityScore ?? 0} />
            <p className="text-sm text-muted">{data?.securityScore ?? 0}/100</p>
          </div>
        </CardContent>
      </Card>

      <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        <Card>
          <CardHeader>
            <CardTitle>Dependency Track</CardTitle>
          </CardHeader>
          <CardContent className="space-y-1 text-sm">
            <p>Critical: {data?.dependencyTrack.critical ?? 0}</p>
            <p>High: {data?.dependencyTrack.high ?? 0}</p>
            <p>Medium: {data?.dependencyTrack.medium ?? 0}</p>
            <p>Low: {data?.dependencyTrack.low ?? 0}</p>
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
            <CardTitle>Image & Policy</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm">
            <p>Cosign Signed: {data?.cosignSigned ? "Yes" : "No"}</p>
            <p>OPA Violations: {data?.opaViolations ?? 0}</p>
          </CardContent>
        </Card>
      </section>
    </div>
  );
}
