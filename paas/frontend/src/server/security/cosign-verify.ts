import { execFile } from "node:child_process";
import { access, unlink, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { env } from "@/server/config/env";
import { integrationFetch } from "@/server/http/integration-fetch";

const execFileAsync = promisify(execFile);

/** Lab default when sync-cosign-keys-lab.sh mounts the pubkey secret. */
const LAB_MOUNTED_PUBLIC_KEY = "/etc/cosign/cosign.pub";

function normalizePem(raw: string): string {
    let s = String(raw ?? "").trim();
    if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
        s = s.slice(1, -1);
    }
    return s.replace(/\\n/g, "\n").trim();
}

async function pathReadable(filePath: string): Promise<boolean> {
    if (!filePath.trim()) {
        return false;
    }
    try {
        await access(filePath, constants.R_OK);
        return true;
    }
    catch {
        return false;
    }
}

async function resolvePublicKeyFile(): Promise<{
    path: string;
    cleanup: boolean;
}> {
    const candidates = [
        env.COSIGN_PUBLIC_KEY_PATH.trim(),
        LAB_MOUNTED_PUBLIC_KEY
    ].filter(Boolean);
    for (const candidate of candidates) {
        if (await pathReadable(candidate)) {
            return { path: candidate, cleanup: false };
        }
    }
    const pem = normalizePem(env.COSIGN_PUBLIC_KEY);
    if (!pem.includes("BEGIN PUBLIC KEY")) {
        throw new Error("Cosign public key missing (set COSIGN_PUBLIC_KEY_PATH or mount /etc/cosign/cosign.pub)");
    }
    const tempPath = join(tmpdir(), `cosign-pub-${process.pid}-${Date.now()}.pem`);
    await writeFile(tempPath, `${pem}\n`, { mode: 0o600 });
    return { path: tempPath, cleanup: true };
}

function harborBasicAuthHeader(): string | null {
    const user = env.HARBOR_USERNAME.trim();
    const pass = env.HARBOR_PASSWORD.trim();
    if (!user || !pass) {
        return null;
    }
    return `Basic ${Buffer.from(`${user}:${pass}`).toString("base64")}`;
}

/** Resolve tag → digest ref via Harbor API (Kyverno verifyImages matches digest). */
function parseHarborImageRef(imageRef: string): {
    harborProject: string;
    repository: string;
    reference: string;
    repoPrefix: string;
} | null {
    const registry = env.HARBOR_REGISTRY.trim();
    if (!registry || !imageRef.startsWith(`${registry}/`)) {
        return null;
    }
    const withoutRegistry = imageRef.slice(registry.length + 1);
    let reference = "";
    let repoPath = withoutRegistry;
    if (withoutRegistry.includes("@sha256:")) {
        const at = withoutRegistry.lastIndexOf("@sha256:");
        repoPath = withoutRegistry.slice(0, at);
        reference = withoutRegistry.slice(at + 1);
    }
    else if (withoutRegistry.includes(":")) {
        const colon = withoutRegistry.lastIndexOf(":");
        repoPath = withoutRegistry.slice(0, colon);
        reference = withoutRegistry.slice(colon + 1);
    }
    else {
        return null;
    }
    const slash = repoPath.indexOf("/");
    if (slash <= 0 || !reference.trim()) {
        return null;
    }
    return {
        harborProject: repoPath.slice(0, slash),
        repository: repoPath.slice(slash + 1),
        reference: reference.trim(),
        repoPrefix: `${registry}/${repoPath}`
    };
}

async function harborDigestRefForTag(imageRef: string): Promise<string | null> {
    const base = env.HARBOR_BASE_URL.trim().replace(/\/+$/, "");
    const auth = harborBasicAuthHeader();
    const parsed = parseHarborImageRef(imageRef);
    if (!base || !auth || !parsed || parsed.reference.startsWith("sha256:")) {
        return null;
    }
    const url = `${base}/api/v2.0/projects/${encodeURIComponent(parsed.harborProject)}`
        + `/repositories/${encodeURIComponent(parsed.repository)}/artifacts/${encodeURIComponent(parsed.reference)}`;
    try {
        const response = await integrationFetch(url, {
            method: "GET",
            headers: { Authorization: auth }
        });
        if (!response.ok) {
            return null;
        }
        const payload = (await response.json()) as { digest?: string };
        const digest = payload.digest?.trim();
        if (!digest?.startsWith("sha256:")) {
            return null;
        }
        return `${parsed.repoPrefix}@${digest}`;
    }
    catch {
        return null;
    }
}

/** Harbor stores cosign signatures as accessories — works when pod cosign CLI cannot reach NodePort sigs. */
async function harborArtifactHasCosignSignature(imageRef: string): Promise<boolean> {
    const base = env.HARBOR_BASE_URL.trim().replace(/\/+$/, "");
    const auth = harborBasicAuthHeader();
    const parsed = parseHarborImageRef(imageRef);
    if (!base || !auth || !parsed) {
        return false;
    }
    const artifactBase = `${base}/api/v2.0/projects/${encodeURIComponent(parsed.harborProject)}`
        + `/repositories/${encodeURIComponent(parsed.repository)}/artifacts/${encodeURIComponent(parsed.reference)}`;
    const hasCosignType = (value: unknown): boolean => {
        if (typeof value !== "string") {
            return false;
        }
        const lower = value.toLowerCase();
        return lower.includes("cosign") || lower.includes("signature");
    };
    const scanPayload = (payload: unknown): boolean => {
        if (!payload || typeof payload !== "object") {
            return false;
        }
        const row = payload as Record<string, unknown>;
        if (row.addition_links && typeof row.addition_links === "object") {
            const links = row.addition_links as Record<string, unknown>;
            if ("signatures" in links) {
                return true;
            }
        }
        const accessories = row.accessories;
        if (Array.isArray(accessories)) {
            for (const item of accessories) {
                if (!item || typeof item !== "object") {
                    continue;
                }
                const acc = item as Record<string, unknown>;
                if (hasCosignType(String(acc.artifact_type ?? acc.type ?? ""))) {
                    return true;
                }
            }
        }
        const refs = row.references;
        if (Array.isArray(refs)) {
            for (const item of refs) {
                if (!item || typeof item !== "object") {
                    continue;
                }
                const ref = item as Record<string, unknown>;
                const annotations = ref.annotations;
                if (annotations && typeof annotations === "object") {
                    for (const [key, val] of Object.entries(annotations as Record<string, unknown>)) {
                        if (hasCosignType(key) || hasCosignType(String(val ?? ""))) {
                            return true;
                        }
                    }
                }
            }
        }
        return false;
    };
    try {
        const artifactRes = await integrationFetch(artifactBase, {
            method: "GET",
            headers: { Authorization: auth }
        });
        if (artifactRes.ok) {
            const artifact = await artifactRes.json();
            if (scanPayload(artifact)) {
                return true;
            }
        }
        const accessoriesRes = await integrationFetch(`${artifactBase}/accessories`, {
            method: "GET",
            headers: { Authorization: auth }
        });
        if (!accessoriesRes.ok) {
            return false;
        }
        const accessories = await accessoriesRes.json();
        if (Array.isArray(accessories)) {
            return accessories.some((item) => {
                if (!item || typeof item !== "object") {
                    return false;
                }
                const acc = item as Record<string, unknown>;
                return hasCosignType(String(acc.artifact_type ?? acc.type ?? ""));
            });
        }
        return scanPayload(accessories);
    }
    catch {
        return false;
    }
}

/** Try in-cluster nginx first, then external NodePort (with docker config), then raw registry. */
function imageRefsForVerify(imageRef: string): string[] {
    const refs: string[] = [];
    const slash = imageRef.indexOf("/");
    if (slash <= 0) {
        return [imageRef.trim()];
    }
    const repoTag = imageRef.slice(slash + 1);
    const external = env.HARBOR_REGISTRY.trim();
    const nginx = env.HARBOR_REGISTRY_NGINX_CLUSTER.trim();
    const cluster = env.HARBOR_REGISTRY_CLUSTER.trim();
    // Lab images are signed via HARBOR_REGISTRY (NodePort); try that before in-cluster nginx.
    if (external && imageRef.startsWith(`${external}/`)) {
        refs.push(imageRef.trim());
    }
    if (external && nginx && imageRef.startsWith(`${external}/`)) {
        refs.push(`${nginx}/${repoTag}`);
    }
    else if (!refs.length) {
        refs.push(imageRef.trim());
    }
    if (external && cluster && imageRef.startsWith(`${external}/`)) {
        refs.push(`${cluster}/${repoTag}`);
    }
    return [...new Set(refs.filter(Boolean))];
}

function cosignVerifyArgs(
    keyPath: string,
    imageRef: string,
    options?: { useRegistryCliAuth?: boolean; dockerConfig?: string }
): string[] {
    const args = ["verify", "--key", keyPath];
    if (env.COSIGN_ALLOW_INSECURE_REGISTRY === "true") {
        args.push("--allow-insecure-registry");
    }
    const user = env.HARBOR_USERNAME.trim();
    const pass = env.HARBOR_PASSWORD.trim();
    if (options?.useRegistryCliAuth && user && pass) {
        args.push("--registry-username", user, "--registry-password", pass);
    }
    args.push(imageRef);
    return args;
}

async function runCosignVerify(
    keyPath: string,
    imageRef: string,
    timeoutMs: number,
    options?: { useRegistryCliAuth?: boolean; dockerConfig?: string }
): Promise<void> {
    const bin = env.COSIGN_BINARY_PATH.trim() || "cosign";
    const dockerConfig = options?.dockerConfig
        ?? process.env.DOCKER_CONFIG?.trim()
        ?? "/etc/docker";
    await execFileAsync(bin, cosignVerifyArgs(keyPath, imageRef, options), {
        timeout: timeoutMs,
        maxBuffer: 10 * 1024 * 1024,
        windowsHide: true,
        env: {
            ...process.env,
            DOCKER_CONFIG: dockerConfig
        }
    });
}

export async function verifyImageWithCosign(imageRef: string, options?: {
    timeoutMs?: number;
}): Promise<boolean> {
    if (env.COSIGN_ENFORCE_SIGNED === "false") {
        return true;
    }
    let keyFile: { path: string; cleanup: boolean } | null = null;
    try {
        keyFile = await resolvePublicKeyFile();
    }
    catch {
        return false;
    }
    const timeout = options?.timeoutMs ?? 180000;
    const refs = [...imageRefsForVerify(imageRef)];
    if (imageRef.includes(":") && !imageRef.includes("@sha256:")) {
        const digestRef = await harborDigestRefForTag(imageRef);
        if (digestRef) {
            refs.push(...imageRefsForVerify(digestRef));
        }
    }
    const verifyAttempts: Array<{ useRegistryCliAuth: boolean; dockerConfig: string }> = [
        { useRegistryCliAuth: false, dockerConfig: process.env.DOCKER_CONFIG?.trim() || "/etc/docker" },
        { useRegistryCliAuth: true, dockerConfig: process.env.DOCKER_CONFIG?.trim() || "/etc/docker" },
        { useRegistryCliAuth: true, dockerConfig: "" }
    ];
    try {
        for (const ref of [...new Set(refs)]) {
            for (const attempt of verifyAttempts) {
                try {
                    await runCosignVerify(keyFile.path, ref, timeout, attempt);
                    return true;
                }
                catch {
                    continue;
                }
            }
        }
        if (await harborArtifactHasCosignSignature(imageRef)) {
            return true;
        }
        const digestOnly = await harborDigestRefForTag(imageRef);
        if (digestOnly && digestOnly !== imageRef && await harborArtifactHasCosignSignature(digestOnly)) {
            return true;
        }
        return false;
    }
    finally {
        if (keyFile?.cleanup) {
            try {
                await unlink(keyFile.path);
            }
            catch {
            }
        }
    }
}

/** Exported for lab shell scripts mirroring Security API verify behaviour. */
export function buildCosignVerifyCliArgs(
    keyPath: string,
    imageRef: string,
    options?: { useRegistryCliAuth?: boolean }
): string[] {
    return cosignVerifyArgs(keyPath, imageRef, options);
}

export { imageRefsForVerify };
