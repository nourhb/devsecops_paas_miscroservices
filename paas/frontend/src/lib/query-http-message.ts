function pickBody(err: unknown): Record<string, unknown> | null {
    if (typeof err !== "object" || err === null || !("response" in err)) {
        return null;
    }
    const body = (err as {
        response?: {
            data?: unknown;
        };
    }).response?.data;
    if (typeof body !== "object" || body === null) {
        return null;
    }
    return body as Record<string, unknown>;
}
export function queryHttpMessage(err: unknown, fallback: string): string {
    const body = pickBody(err);
    const msg = body?.message;
    if (typeof msg === "string" && msg.trim()) {
        return msg;
    }
    if (err instanceof Error && err.message.trim()) {
        return err.message;
    }
    return fallback;
}
export function queryHttpDetails(err: unknown): string | null {
    const body = pickBody(err);
    const d = body?.details;
    return typeof d === "string" && d.trim() ? d : null;
}
export function queryHttpData(err: unknown): Record<string, unknown> | null {
    return pickBody(err);
}
