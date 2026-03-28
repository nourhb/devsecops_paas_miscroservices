import { exec } from "node:child_process";
import { promisify } from "node:util";
import { prisma } from "../prisma";

const execAsync = promisify(exec);

export interface TrivyScanResult {
  ok: boolean;
  imageRef: string;
  vulnerabilities: unknown[];
  rawOutput?: string;
}

export async function runImageScan(
  pipelineId: string,
  imageRef: string,
): Promise<TrivyScanResult> {
  try {
    const { stdout } = await execAsync(
      `trivy image --quiet --format json ${imageRef}`,
      {
        maxBuffer: 10 * 1024 * 1024,
      },
    );

    const parsed = JSON.parse(stdout) as any;
    const vulnerabilities = parsed.Results ?? [];

    // Derive a simple "severity" summary for storage
    const severities = new Set<string>();
    for (const r of vulnerabilities) {
      for (const v of r.Vulnerabilities ?? []) {
        if (v.Severity) severities.add(v.Severity as string);
      }
    }

    const severitySummary =
      severities.size > 0 ? Array.from(severities).join(",") : "NONE";

    await prisma.scanResult.create({
      data: {
        pipelineId,
        scanner: "trivy",
        severity: severitySummary,
        reportUrl: null,
      },
    });

    return {
      ok: true,
      imageRef,
      vulnerabilities,
      rawOutput: stdout,
    };
  } catch (error) {
    await prisma.scanResult.create({
      data: {
        pipelineId,
        scanner: "trivy",
        severity: "ERROR",
        reportUrl: null,
      },
    });

    const message = (error as Error).message;
    return {
      ok: false,
      imageRef,
      vulnerabilities: [],
      rawOutput: message,
    };
  }
}

