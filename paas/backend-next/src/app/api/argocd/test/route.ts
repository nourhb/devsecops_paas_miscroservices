import { NextResponse } from "next/server";
import { getApplicationStatus } from "../../../../lib/services/argocd";
export async function GET() {
    const appName = process.env.ARGOCD_TEST_APP ?? "argocd-health-check";
    try {
        await getApplicationStatus(appName);
        return NextResponse.json({ ok: true });
    }
    catch (error) {
        return NextResponse.json({ ok: false, error: (error as Error).message }, { status: 500 });
    }
}
