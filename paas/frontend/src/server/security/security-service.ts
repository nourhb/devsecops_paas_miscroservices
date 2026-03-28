import type { SecurityMetrics } from "@/types";
import { getProjectById } from "@/server/projects/project-service";
import {
  cosignClient,
  dependencyTrackClient,
  opaClient,
  sonarQubeClient,
  trivyClient
} from "@/server/integrations/devsecops-clients";

function score(base: number, penalty: number): number {
  const scored = base - penalty;
  return Math.max(0, Math.min(100, scored));
}

export async function getSecurityMetrics(projectId: string): Promise<SecurityMetrics> {
  const project = await getProjectById(projectId);
  const imageTag = project.imageTag || `${project.projectName}:latest`;

  const qualityGate = await sonarQubeClient.qualityGate(project.projectName);
  const dependencyTrack = await dependencyTrackClient.vulnerabilities(project.projectName);
  const trivy = await trivyClient.scan(imageTag);
  const cosignSigned = await cosignClient.isSigned(imageTag);
  const opaAllowed = await opaClient.isAllowed(imageTag, cosignSigned);

  const severityPenalty =
    dependencyTrack.critical * 15 +
    dependencyTrack.high * 8 +
    dependencyTrack.medium * 3 +
    trivy.critical * 20 +
    trivy.high * 10 +
    trivy.medium * 4;

  const gatePenalty =
    (qualityGate.status === "FAILED" ? 20 : 0) +
    (!cosignSigned ? 20 : 0) +
    (!opaAllowed ? 20 : 0);

  const securityScore = score(100, severityPenalty + gatePenalty);

  return {
    qualityGateStatus: qualityGate.status,
    dependencyTrack,
    trivy,
    cosignSigned,
    opaViolations: opaAllowed ? 0 : 1,
    securityScore
  };
}
