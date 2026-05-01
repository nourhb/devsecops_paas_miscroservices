import { NextResponse } from "next/server";
import { getNodeCount } from "../../../../lib/services/kubernetes";
export async function GET() {
    try {
        const count = await getNodeCount();
        return NextResponse.json({ ok: true, nodeCount: count });
    }
    catch (error) {
        return NextResponse.json({ ok: false, error: (error as Error).message }, { status: 500 });
    }
}
