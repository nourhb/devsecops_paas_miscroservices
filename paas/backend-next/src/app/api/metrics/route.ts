import { NextResponse } from "next/server";
import axios from "axios";
import { prisma } from "../../../lib/prisma";
import { listPodsForDeployment } from "../../../lib/services/kubernetes";
export const dynamic = "force-dynamic";
interface ClusterMetrics {
    nodeCount: number;
    cpuUsagePercent: number;
    memoryUsagePercent: number;
}
interface PipelineSummary {
    id: string;
    projectId: string;
    status: string;
    buildNumber: number | null;
    createdAt: string;
}
interface DeploymentSummary {
    runningPods: number;
    failedPods: number;
    lastDeploymentTime: string | null;
}
interface SecuritySummary {
    trivyVulnerabilities: string;
    sonarQualityGate: string | null;
    signedImages: number;
    unsignedImages: number;
}
async function fetchClusterMetrics(): Promise<ClusterMetrics> {
    const prometheusUrl = process.env.PROMETHEUS_URL;
    if (!prometheusUrl) {
        return {
            nodeCount: 0,
            cpuUsagePercent: 0,
            memoryUsagePercent: 0,
        };
    }
    const client = axios.create({
        baseURL: prometheusUrl.replace(/\/+$/, ""),
    });
    const [nodesResp, cpuResp, memResp] = await Promise.all([
        client.get("/api/v1/query", {
            params: { query: "count(kube_node_info)" },
        }),
        client.get("/api/v1/query", {
            params: {
                query: "100 - (avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
            },
        }),
        client.get("/api/v1/query", {
            params: {
                query: "100 * (1 - ((node_memory_MemAvailable_bytes) / (node_memory_MemTotal_bytes)))",
            },
        }),
    ]);
    const nodeCount = Number(nodesResp.data.data.result?.[0]?.value?.[1] ?? 0) || 0;
    const cpuUsagePercent = Number(cpuResp.data.data.result?.[0]?.value?.[1] ?? 0) || 0;
    const memoryUsagePercent = Number(memResp.data.data.result?.[0]?.value?.[1] ?? 0) || 0;
    return { nodeCount, cpuUsagePercent, memoryUsagePercent };
}
async function fetchPipelines(): Promise<PipelineSummary[]> {
    const pipelines = await prisma.pipeline.findMany({
        orderBy: { createdAt: "desc" },
        take: 10,
    });
    return pipelines.map((p: any) => ({
        id: p.id,
        projectId: p.projectId,
        status: p.status,
        buildNumber: p.buildNumber,
        createdAt: p.createdAt.toISOString(),
    }));
}
async function fetchDeploymentSummary(): Promise<DeploymentSummary> {
    const deployments = await prisma.deployment.findMany({
        orderBy: { createdAt: "desc" },
        take: 1,
    });
    if (deployments.length === 0) {
        return {
            runningPods: 0,
            failedPods: 0,
            lastDeploymentTime: null,
        };
    }
    const latest = deployments[0];
    const pods = await listPodsForDeployment(latest.projectId, latest.namespace);
    const runningPods = pods.filter((p) => p.phase === "Running").length;
    const failedPods = pods.filter((p) => p.phase === "Failed" || p.phase === "Unknown").length;
    return {
        runningPods,
        failedPods,
        lastDeploymentTime: latest.createdAt.toISOString(),
    };
}
async function fetchSecuritySummary(): Promise<SecuritySummary> {
    const scanResults = await prisma.scanResult.findMany({
        orderBy: { id: "desc" },
        take: 50,
    });
    const trivy = scanResults.find((s: any) => s.scanner === "trivy");
    const sonar = scanResults.find((s: any) => s.scanner === "sonarqube");
    const trivyVuln = trivy?.severity ?? "UNKNOWN";
    const sonarGate = sonar?.severity ?? null;
    const signedImages = scanResults.filter((s: any) => s.scanner === "cosign" && s.severity === "SIGNED").length;
    const unsignedImages = scanResults.filter((s: any) => s.scanner === "cosign" && s.severity !== "SIGNED").length;
    return {
        trivyVulnerabilities: trivyVuln,
        sonarQualityGate: sonarGate,
        signedImages,
        unsignedImages,
    };
}
export async function GET() {
    try {
        const [cluster, pipelines, deployments, security] = await Promise.all([
            fetchClusterMetrics(),
            fetchPipelines(),
            fetchDeploymentSummary(),
            fetchSecuritySummary(),
        ]);
        return NextResponse.json({
            cluster,
            pipelines,
            deployments,
            security,
        });
    }
    catch (error) {
        const message = (error as Error).message;
        return NextResponse.json({ error: message }, { status: 500 });
    }
}
