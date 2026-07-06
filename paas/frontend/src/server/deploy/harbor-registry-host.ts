import { env } from "@/server/config/env";

const PRIVATE_IPV4 = /^(\d{1,3}\.){3}\d{1,3}$/;

export function coerceHarborRegistryHostForCosign(host: string): string {
    const trimmed = host.trim().replace(/^https?:\/\//i, "").replace(/\/$/, "");
    if (!trimmed) {
        return "";
    }
    const colon = trimmed.lastIndexOf(":");
    const hasPort = colon > 0 && !trimmed.slice(0, colon).includes("/");
    const name = hasPort ? trimmed.slice(0, colon) : trimmed;
    const port = hasPort ? trimmed.slice(colon + 1) : "";
    if (!PRIVATE_IPV4.test(name)) {
        return trimmed;
    }
    const nip = `harbor.${name}.nip.io`;
    return port ? `${nip}:${port}` : nip;
}

export function harborIpRegistryHostFromNipio(host: string): string {
    const trimmed = host.trim().replace(/^https?:\/\//i, "").replace(/\/$/, "");
    if (!trimmed) {
        return "";
    }
    const colon = trimmed.lastIndexOf(":");
    const hasPort = colon > 0 && !trimmed.slice(0, colon).includes("/");
    const name = hasPort ? trimmed.slice(0, colon) : trimmed;
    const port = hasPort ? trimmed.slice(colon + 1) : "";
    const m = name.match(/^harbor\.(\d{1,3}(?:\.\d{1,3}){3})\.nip\.io$/i);
    if (!m) {
        return trimmed;
    }
    const ip = m[1];
    return port ? `${ip}:${port}` : ip;
}

export function normalizeHarborImageRef(imageRef: string): string {
    const ref = imageRef.trim();
    if (!ref) {
        return ref;
    }
    const slash = ref.indexOf("/");
    if (slash <= 0) {
        return ref;
    }
    const host = ref.slice(0, slash);
    const rest = ref.slice(slash);
    const coerced = coerceHarborRegistryHostForCosign(host);
    if (coerced === host) {
        return ref;
    }
    return `${coerced}${rest}`;
}

export function harborBaseUrlFromRegistryHost(host: string): string {
    const registry = coerceHarborRegistryHostForCosign(host);
    if (!registry) {
        return "";
    }
    return `http://${registry}`;
}

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
            [registry]: { username, password, auth }
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
