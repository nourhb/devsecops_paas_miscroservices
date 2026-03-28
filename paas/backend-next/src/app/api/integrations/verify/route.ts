import { NextResponse } from 'next/server';
import { db } from '../../../../lib/in-memory-db';
import { verifyAll } from '../../../../lib/services/integrations';

export async function POST(req: Request) {
  // Accept optional projectId or imageRef in body for targeted verification in future
  const body = await (async () => {
    try { return await req.json(); } catch { return {}; }
  })();

  // If a projectId is provided, ensure project exists
  if (body.projectId && !db.projects.has(body.projectId)) {
    return NextResponse.json({ error: 'project_not_found' }, { status: 404 });
  }

  const results = await verifyAll();

  // Simulate more detailed pipeline verification in future; for now return probe results
  return NextResponse.json({ verified: true, components: results });
}
