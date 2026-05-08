export function formatFetchErrorChain(error: unknown): string {
    if (!(error instanceof Error)) {
        return String(error);
    }
    const parts: string[] = [];
    let cur: unknown = error;
    for (let depth = 0; depth < 8 && cur; depth++) {
        if (cur instanceof Error) {
            const code = (cur as NodeJS.ErrnoException).code;
            const chunk = code && !cur.message.includes(String(code)) ? `${cur.message} (${code})` : cur.message;
            if (chunk) {
                parts.push(chunk);
            }
            cur = "cause" in cur ? cur.cause : undefined;
        }
        else if (typeof cur === "object" && cur !== null && "message" in cur) {
            parts.push(String((cur as {
                message: unknown;
            }).message));
            break;
        }
        else {
            break;
        }
    }
    return parts.join(" \u2014 ");
}
