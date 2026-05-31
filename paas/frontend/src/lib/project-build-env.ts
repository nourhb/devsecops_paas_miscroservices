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

export function formatBuildEnvText(env: Record<string, string> | null | undefined): string {
    if (!env) {
        return "";
    }
    return Object.entries(env)
        .filter(([key, value]) => KEY_PATTERN.test(key) && value.length > 0)
        .map(([key, value]) => `${key}=${value}`)
        .join("\n");
}
