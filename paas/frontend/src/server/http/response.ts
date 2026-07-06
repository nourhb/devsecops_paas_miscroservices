export class ApiError extends Error {
    status: number;
    details?: string;
    data?: Record<string, unknown>;
    constructor(status: number, message: string, options?: {
        details?: string;
        data?: Record<string, unknown>;
    }) {
        super(message);
        this.status = status;
        this.details = options?.details;
        this.data = options?.data;
    }
}
export class UnauthorizedError extends ApiError {
    constructor(message = "Unauthorized") {
        super(401, message);
    }
}
export class ForbiddenError extends ApiError {
    constructor(message = "Forbidden") {
        super(403, message);
    }
}
export class NotFoundError extends ApiError {
    constructor(message = "Not found") {
        super(404, message);
    }
}
export class ValidationError extends ApiError {
    constructor(message = "Bad request") {
        super(400, message);
    }
}
export class SecurityGateError extends ApiError {
    constructor(message = "Security gate failed") {
        super(422, message);
    }
}
export class IntegrationError extends ApiError {
    constructor(message: string, options?: {
        details?: string;
        data?: Record<string, unknown>;
    }) {
        super(502, message, options);
    }
}
export class ServiceUnavailableError extends ApiError {
    constructor(message = "Service temporarily unavailable") {
        super(503, message);
    }
}

import { NextResponse } from "next/server";
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
