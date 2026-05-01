import { NextResponse } from 'next/server';
import { db } from '../../../../lib/in-memory-db';
import { verifyAll } from '../../../../lib/services/integrations';
export async function POST(req: Request) {
    const body = await (async () => {
        try {
            return await req.json();
        }
        catch {
            return {};
        }
    })();
    if (body.projectId && !db.projects.has(body.projectId)) {
        return NextResponse.json({ error: 'project_not_found' }, { status: 404 });
    }
    const results = await verifyAll();
    return NextResponse.json({ verified: true, components: results });
}
