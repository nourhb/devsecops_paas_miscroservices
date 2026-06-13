import { env } from "@/server/config/env";

export function buildHarborDockerConfigJson(): string | null {
    const registry = env.HARBOR_REGISTRY.trim() || env.HARBOR_BASE_URL.trim().replace(/^https?:\/\//, "").replace(/\/$/, "").split("/")[0];
    const username = env.HARBOR_USERNAME.trim();
    const password = env.HARBOR_PASSWORD.trim();
    if (!registry || !username || !password) {
        return null;
    }
    const auth = Buffer.from(`${username}:${password}`, "utf8").toString("base64");
    return JSON.stringify({
        auths: {
            [registry]: {
                username,
                password,
                auth
            }
        }
    });
}

export function harborDockerConfigSecretData(): Record<string, string> | null {
    const dockerConfig = buildHarborDockerConfigJson();
    if (!dockerConfig) {
        return null;
    }
    return {
        ".dockerconfigjson": Buffer.from(dockerConfig, "utf8").toString("base64")
    };
}
