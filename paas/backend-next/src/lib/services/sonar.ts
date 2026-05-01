import axios from "axios";
import { prisma } from "../prisma";
export interface SonarAnalysisRequest {
    projectKey: string;
    branch: string;
    commitSha: string;
    pipelineId: string;
}
export interface SonarAnalysisStatus {
    projectKey: string;
    status: "PENDING" | "RUNNING" | "PASSED" | "FAILED";
    qualityGateStatus?: "OK" | "WARN" | "ERROR";
    dashboardUrl?: string;
}
function getSonarClient() {
    const baseUrl = process.env.SONAR_URL;
    const token = process.env.SONAR_TOKEN;
    if (!baseUrl || !token) {
        throw new Error("SonarQube configuration missing (SONAR_URL/TOKEN).");
    }
    return axios.create({
        baseURL: baseUrl.replace(/\/+$/, ""),
        headers: {
            Authorization: `Basic ${Buffer.from(`${token}:`).toString("base64")}`,
        },
    });
}
export async function triggerSonarAnalysis(req: SonarAnalysisRequest): Promise<SonarAnalysisStatus> {
    const client = getSonarClient();
    await client.post("/api/projects/create", null, {
        params: {
            project: req.projectKey,
            name: req.projectKey,
        },
    }).catch(() => {
    });
    await prisma.scanResult.create({
        data: {
            pipelineId: req.pipelineId,
            scanner: "sonarqube",
            severity: "PENDING",
            reportUrl: `${process.env.SONAR_URL}/dashboard?id=${encodeURIComponent(req.projectKey)}`,
        },
    });
    return {
        projectKey: req.projectKey,
        status: "PENDING",
        dashboardUrl: `${process.env.SONAR_URL}/dashboard?id=${encodeURIComponent(req.projectKey)}`,
    };
}
export async function getSonarAnalysisStatus(projectKey: string): Promise<SonarAnalysisStatus> {
    const client = getSonarClient();
    const { data } = await client.get("/api/qualitygates/project_status", {
        params: { projectKey },
    });
    const status = data.projectStatus?.status as "OK" | "WARN" | "ERROR" | undefined;
    return {
        projectKey,
        status: status === "OK" ? "PASSED" : "FAILED",
        qualityGateStatus: status,
        dashboardUrl: `${process.env.SONAR_URL}/dashboard?id=${encodeURIComponent(projectKey)}`,
    };
}
