import { NextResponse } from "next/server";
import { ApiError } from "@/server/http/errors";
export function ok<T>(payload: T, init?: ResponseInit) {
    return NextResponse.json(payload, { status: 200, ...init });
}
export function created<T>(payload: T) {
    return NextResponse.json(payload, { status: 201 });
}
function friendlyDbBootMessage(raw: string): string | null {
    if (!/can't reach database server|connection refused|ECONNREFUSED|P1001|P1017|connection pool/i.test(raw)) {
        return null;
    }
    return "Database is still starting. Wait a few minutes and try again, or check the Postgres workload in the paas namespace.";
}

export function fail(error: unknown) {
    if (error instanceof ApiError) {
        return NextResponse.json({
            message: error.message,
            ...(error.details ? { details: error.details } : {}),
            ...(error.data ?? {})
        }, { status: error.status });
    }
    const message = error instanceof Error ? error.message : "Internal server error";
    const dbMessage = friendlyDbBootMessage(message);
    if (dbMessage) {
        return NextResponse.json({ message: dbMessage }, { status: 503 });
    }
    return NextResponse.json({ message }, { status: 500 });
}
