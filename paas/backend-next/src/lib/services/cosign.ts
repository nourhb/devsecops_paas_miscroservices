import { exec } from "node:child_process";
import { promisify } from "node:util";
const execAsync = promisify(exec);
export interface CosignSignResult {
    imageRef: string;
    signed: boolean;
    signatureDigest?: string;
}
export interface CosignVerifyResult {
    imageRef: string;
    verified: boolean;
    reason?: string;
}
export async function signImage(imageRef: string): Promise<CosignSignResult> {
    const keyRef = process.env.COSIGN_KEY_REF ?? "env://COSIGN_KEY";
    try {
        const { stdout } = await execAsync(`cosign sign --yes --key ${keyRef} ${imageRef}`, {
            maxBuffer: 5 * 1024 * 1024,
        });
        const match = stdout.match(/sha256:[0-9a-fA-F]{64}/);
        return {
            imageRef,
            signed: true,
            signatureDigest: match ? match[0] : undefined,
        };
    }
    catch (error) {
        return {
            imageRef,
            signed: false,
            signatureDigest: undefined,
        };
    }
}
export async function verifyImageSignature(imageRef: string): Promise<CosignVerifyResult> {
    try {
        await execAsync(`cosign verify ${imageRef}`, {
            maxBuffer: 5 * 1024 * 1024,
        });
        return {
            imageRef,
            verified: true,
        };
    }
    catch (error) {
        return {
            imageRef,
            verified: false,
            reason: (error as Error).message,
        };
    }
}
