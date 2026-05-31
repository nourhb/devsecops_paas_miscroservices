import { execFile } from "node:child_process";
import { access, unlink, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { env } from "@/server/config/env";

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

/** Try external NodePort and in-cluster Harbor registry hosts (pods cannot always reach NodePort). */
function imageRefsForVerify(imageRef: string): string[] {
    const refs = [imageRef.trim()];
    const slash = imageRef.indexOf("/");
    if (slash <= 0) {
        return refs;
    }
    const repoTag = imageRef.slice(slash + 1);
    const external = env.HARBOR_REGISTRY.trim();
    const cluster = env.HARBOR_REGISTRY_CLUSTER.trim();
    if (external && cluster && imageRef.startsWith(`${external}/`)) {
        refs.push(`${cluster}/${repoTag}`);
    }
    const nginx = env.HARBOR_REGISTRY_NGINX_CLUSTER.trim();
    if (external && nginx && imageRef.startsWith(`${external}/`)) {
        refs.push(`${nginx}/${repoTag}`);
    }
    return [...new Set(refs.filter(Boolean))];
}

function cosignVerifyArgs(keyPath: string, imageRef: string): string[] {
    const args = ["verify", "--key", keyPath];
    if (env.COSIGN_ALLOW_INSECURE_REGISTRY === "true") {
        args.push("--allow-insecure-registry");
    }
    const user = env.HARBOR_USERNAME.trim();
    const pass = env.HARBOR_PASSWORD.trim();
    if (user && pass) {
        args.push("--registry-username", user, "--registry-password", pass);
    }
    args.push(imageRef);
    return args;
}

async function runCosignVerify(keyPath: string, imageRef: string, timeoutMs: number): Promise<void> {
    const bin = env.COSIGN_BINARY_PATH.trim() || "cosign";
    await execFileAsync(bin, cosignVerifyArgs(keyPath, imageRef), {
        timeout: timeoutMs,
        maxBuffer: 10 * 1024 * 1024,
        windowsHide: true
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
    try {
        for (const ref of imageRefsForVerify(imageRef)) {
            try {
                await runCosignVerify(keyFile.path, ref, timeout);
                return true;
            }
            catch {
                continue;
            }
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
export function buildCosignVerifyCliArgs(keyPath: string, imageRef: string): string[] {
    return cosignVerifyArgs(keyPath, imageRef);
}

export { imageRefsForVerify };
