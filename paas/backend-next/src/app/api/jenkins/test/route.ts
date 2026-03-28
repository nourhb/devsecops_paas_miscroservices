import { NextResponse } from "next/server";
import { createPipelineJob, deleteJob } from "../../../../lib/services/jenkins";

export async function GET() {
  const jobName = "health-check-job";

  try {
    // Try to create and then delete a tiny job to validate connectivity/creds
    await createPipelineJob(jobName, "https://example.com/health.git");
    await deleteJob(jobName);

    return NextResponse.json({ ok: true });
  } catch (error) {
    return NextResponse.json(
      { ok: false, error: (error as Error).message },
      { status: 500 },
    );
  }
}

