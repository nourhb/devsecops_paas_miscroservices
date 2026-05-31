const KEY_PATTERN = /^[A-Za-z_][A-Za-z0-9_]{0,119}$/;

export function parseBuildEnvText(text: string): Record<string, string> {
    const out: Record<string, string> = {};
    for (const line of text.split(/\r?\n/)) {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith("#")) {
            continue;
        }
        const eq = trimmed.indexOf("=");
        if (eq <= 0) {
            continue;
        }
        const key = trimmed.slice(0, eq).trim();
        const value = trimmed.slice(eq + 1);
        if (!KEY_PATTERN.test(key)) {
            continue;
        }
        out[key] = value.slice(0, 4000);
    }
    return out;
}

export function formatBuildEnvText(env: unknown): string {
    if (!env || typeof env !== "object" || Array.isArray(env)) {
        return "";
    }
    return Object.entries(env as Record<string, unknown>)
        .filter(([key, value]) => KEY_PATTERN.test(key) && typeof value === "string" && value.length > 0)
        .map(([key, value]) => `${key}=${value}`)
        .join("\n");
}

export function normalizeBuildEnvInput(raw: unknown): Record<string, string> | null {
    if (raw == null) {
        return null;
    }
    if (typeof raw === "string") {
        const parsed = parseBuildEnvText(raw);
        return Object.keys(parsed).length > 0 ? parsed : null;
    }
    if (typeof raw !== "object" || Array.isArray(raw)) {
        return null;
    }
    const out: Record<string, string> = {};
    for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
        if (!KEY_PATTERN.test(key) || typeof value !== "string" || !value.trim()) {
            continue;
        }
        out[key] = value.slice(0, 4000);
    }
    return Object.keys(out).length > 0 ? out : null;
}

export function encodeBuildEnvForJenkins(buildEnv: Record<string, string> | null | undefined): string {
    if (!buildEnv || Object.keys(buildEnv).length === 0) {
        return "";
    }
    return Buffer.from(JSON.stringify(buildEnv), "utf8").toString("base64");
}

export function mergeBuildEnvIntoHelmValues(doc: Record<string, unknown>, buildEnv: Record<string, string> | null | undefined): void {
    if (!buildEnv || Object.keys(buildEnv).length === 0) {
        return;
    }
    const rows = Array.isArray(doc.env) ? [...(doc.env as Array<{ name?: string; value?: string }>)] : [];
    const byName = new Map<string, { name: string; value: string }>();
    for (const row of rows) {
        const name = String(row?.name ?? "").trim();
        if (!name) {
            continue;
        }
        byName.set(name, { name, value: String(row?.value ?? "") });
    }
    for (const [name, value] of Object.entries(buildEnv)) {
        byName.set(name, { name, value });
    }
    doc.env = Array.from(byName.values());
}
