type AuditLogInput = {
    action: string;
    outcome: "success" | "failure";
    actorId?: string | null;
    actorEmail?: string | null;
    targetType?: string;
    targetId?: string | null;
    metadata?: Record<string, unknown>;
};
export function writeAuditLog(input: AuditLogInput) {
    console.info(JSON.stringify({
        ts: new Date().toISOString(),
        type: "audit",
        ...input
    }));
}
