import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { env } from "@/server/config/env";
const execFileAsync = promisify(execFile);
export async function verifyImageWithCosign(imageRef: string, options?: {
    timeoutMs?: number;
}): Promise<boolean> {
    if (env.COSIGN_ENFORCE_SIGNED === "false") {
        return true;
    }
    const pem = env.COSIGN_PUBLIC_KEY.trim();
    if (!pem) {
        return false;
    }
    const keyPath = join(tmpdir(), `cosign-pub-${process.pid}-${Date.now()}.pem`);
    await writeFile(keyPath, `${pem}\n`, { mode: 384 });
    try {
        const bin = env.COSIGN_BINARY_PATH.trim() || "cosign";
        const timeout = options?.timeoutMs ?? 180000;
        await execFileAsync(bin, ["verify", "--key", keyPath, imageRef], {
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
        try {
            await unlink(keyPath);
        }
        catch {
        }
    }
}
