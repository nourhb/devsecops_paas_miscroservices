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
