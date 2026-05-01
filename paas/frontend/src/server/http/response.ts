import { NextResponse } from "next/server";
import { ApiError } from "@/server/http/errors";
export function ok<T>(payload: T, init?: ResponseInit) {
    return NextResponse.json(payload, { status: 200, ...init });
}
export function created<T>(payload: T) {
    return NextResponse.json(payload, { status: 201 });
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
    return NextResponse.json({ message }, { status: 500 });
}
