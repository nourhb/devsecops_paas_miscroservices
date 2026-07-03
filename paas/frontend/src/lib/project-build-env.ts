const KEY_PATTERN = /^[A-Za-z_][A-Za-z0-9_]{0,119}$/;

function stripEnvValueQuotes(value: string): string {
    const trimmed = value.trim();
    if (trimmed.length >= 2) {
        const first = trimmed[0];
        const last = trimmed[trimmed.length - 1];
        if ((first === "\"" && last === "\"") || (first === "'" && last === "'")) {
            return trimmed.slice(1, -1);
        }
    }
    return value;
}

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
        const value = stripEnvValueQuotes(trimmed.slice(eq + 1));
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
