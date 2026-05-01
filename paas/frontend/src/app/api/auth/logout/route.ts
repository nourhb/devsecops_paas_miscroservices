import { NextRequest, NextResponse } from "next/server";
import { buildExpiredSessionCookie } from "@/server/auth/session-cookie";
export const runtime = "nodejs";
export async function POST(_request: NextRequest) {
    const response = NextResponse.json({ success: true });
    response.cookies.set(buildExpiredSessionCookie());
    return response;
}
