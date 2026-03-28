import { NextResponse } from "next/server";
import { createRepository, deleteRepository } from "../../../../lib/services/harbor";

export async function GET() {
  const project = process.env.HARBOR_TEST_PROJECT ?? "library";
  const repo = "health-check";

  try {
    await createRepository(project, repo);
    await deleteRepository(project, repo);

    return NextResponse.json({ ok: true });
  } catch (error) {
    return NextResponse.json(
      { ok: false, error: (error as Error).message },
      { status: 500 },
    );
  }
}

