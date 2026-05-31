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
    try {
        const bin = env.COSIGN_BINARY_PATH.trim() || "cosign";
        const timeout = options?.timeoutMs ?? 180000;
        const args = ["verify", "--key", keyFile.path];
        if (env.COSIGN_ALLOW_INSECURE_REGISTRY === "true") {
            args.push("--allow-insecure-registry");
        }
        args.push(imageRef);
        await execFileAsync(bin, args, {
            timeout,
            maxBuffer: 10 * 1024 * 1024,
            windowsHide: true
        });
        return true;
    }
    catch {
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
