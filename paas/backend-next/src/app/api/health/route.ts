import { NextResponse } from "next/server";
export async function GET() {
    const now = new Date().toISOString();
    return NextResponse.json({
        ok: true,
        status: "up",
        timestamp: now,
        services: {
            jenkins: "/api/test/jenkins",
            harbor: "/api/test/harbor",
            argocd: "/api/test/argocd",
            kubernetes: "/api/test/kubernetes",
        },
    });
}
