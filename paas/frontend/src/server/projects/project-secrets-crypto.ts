import crypto from "node:crypto";
import { env } from "@/server/config/env";
import { ValidationError } from "@/server/http/errors";
import { normalizeBuildEnvInput } from "@/server/projects/project-build-env";

const ENVELOPE_VERSION = 1;
const ALGO = "aes-256-gcm";

export type EncryptedBuildEnvEnvelope = {
    __enc: typeof ENVELOPE_VERSION;
    iv: string;
    tag: string;
    data: string;
};

function deriveEncryptionKey(): Buffer {
    const raw = (process.env.PROJECT_SECRETS_ENCRYPTION_KEY || env.JWT_SECRET || "").trim();
    if (raw.length < 32) {
        throw new Error("Set PROJECT_SECRETS_ENCRYPTION_KEY or JWT_SECRET (min 32 chars) to store project build env secrets.");
    }
    return crypto.createHash("sha256").update(`paas-project-build-env:${raw}`).digest();
}

export function isEncryptedBuildEnvEnvelope(stored: unknown): stored is EncryptedBuildEnvEnvelope {
    return Boolean(stored &&
        typeof stored === "object" &&
        !Array.isArray(stored) &&
        (stored as EncryptedBuildEnvEnvelope).__enc === ENVELOPE_VERSION &&
        typeof (stored as EncryptedBuildEnvEnvelope).iv === "string" &&
        typeof (stored as EncryptedBuildEnvEnvelope).tag === "string" &&
        typeof (stored as EncryptedBuildEnvEnvelope).data === "string");
}

export function encryptBuildEnvPlaintext(plain: Record<string, string>): EncryptedBuildEnvEnvelope {
    const iv = crypto.randomBytes(12);
    const key = deriveEncryptionKey();
    const cipher = crypto.createCipheriv(ALGO, key, iv);
    const ciphertext = Buffer.concat([
        cipher.update(JSON.stringify(plain), "utf8"),
        cipher.final()
    ]);
    return {
        __enc: ENVELOPE_VERSION,
        iv: iv.toString("base64"),
        tag: cipher.getAuthTag().toString("base64"),
        data: ciphertext.toString("base64")
    };
}

export function decryptBuildEnvEnvelope(stored: EncryptedBuildEnvEnvelope): Record<string, string> | null {
    try {
        const key = deriveEncryptionKey();
        const decipher = crypto.createDecipheriv(ALGO, key, Buffer.from(stored.iv, "base64"));
        decipher.setAuthTag(Buffer.from(stored.tag, "base64"));
        const plain = Buffer.concat([
            decipher.update(Buffer.from(stored.data, "base64")),
            decipher.final()
        ]).toString("utf8");
        const parsed = JSON.parse(plain) as unknown;
        return normalizeBuildEnvInput(parsed);
    }
    catch {
        return null;
    }
}

/** Read build env from DB (encrypted envelope or legacy plaintext JSON). */
export function resolveBuildEnvFromStorage(stored: unknown): Record<string, string> | null {
    if (stored == null) {
        return null;
    }
    if (isEncryptedBuildEnvEnvelope(stored)) {
        return decryptBuildEnvEnvelope(stored);
    }
    return normalizeBuildEnvInput(stored);
}

/** Log line for PaaS deploy/build trigger (no secret values). */
export function buildEnvJenkinsTriggerLog(stored: unknown, resolved?: Record<string, string> | null): string {
    const envMap = resolved ?? resolveBuildEnvFromStorage(stored);
    if (!hasBuildEnvStored(stored)) {
        return "[build-env] None configured — add Application environment (.env) in Edit project. NEXT_PUBLIC_* (Firebase) must be present before Jenkins runs next build.";
    }
    if (!envMap || Object.keys(envMap).length === 0) {
        return "[build-env] WARN: Secrets are stored but decryption failed. Set JWT_SECRET (32+ chars) in docker-compose.env, redeploy frontend, re-save build env in Edit project.";
    }
    const keys = Object.keys(envMap);
    const publicCount = keys.filter((k) => k.startsWith("NEXT_PUBLIC_")).length;
    return `[build-env] Forwarding ${keys.length} variable(s) as PROJECT_BUILD_ENV_B64 (${publicCount} NEXT_PUBLIC_* — baked at Jenkins build, not injected at K8s deploy).`;
}

/** True when build env exists in DB; does not decrypt (safe for project list). */
export function hasBuildEnvStored(stored: unknown): boolean {
    if (stored == null) {
        return false;
    }
    if (isEncryptedBuildEnvEnvelope(stored)) {
        return true;
    }
    const plain = normalizeBuildEnvInput(stored);
    return plain !== null && Object.keys(plain).length > 0;
}

export function serializeBuildEnvForStorage(plain: Record<string, string> | null | undefined): EncryptedBuildEnvEnvelope | null {
    if (!plain || Object.keys(plain).length === 0) {
        return null;
    }
    return encryptBuildEnvPlaintext(plain);
}

export type BuildEnvDeployReadiness = {
    configured: boolean;
    decryptOk: boolean;
    keyCount: number;
    nextPublicCount: number;
};

export function assessBuildEnvDeployReadiness(stored: unknown): BuildEnvDeployReadiness {
    const configured = hasBuildEnvStored(stored);
    const resolved = resolveBuildEnvFromStorage(stored);
    const keyCount = resolved ? Object.keys(resolved).length : 0;
    return {
        configured,
        decryptOk: configured && keyCount > 0,
        keyCount,
        nextPublicCount: resolved ? Object.keys(resolved).filter((k) => k.startsWith("NEXT_PUBLIC_")).length : 0
    };
}

/** Block deploy when secrets exist in DB but cannot be decrypted (Jenkins would build without env). */
export function assertBuildEnvReadyForDeploy(stored: unknown): void {
    const status = assessBuildEnvDeployReadiness(stored);
    if (!status.configured) {
        return;
    }
    if (!status.decryptOk) {
        throw new ValidationError("Project build environment is stored but cannot be decrypted. Set JWT_SECRET (32+ characters) in docker-compose.env, redeploy the PaaS frontend, open Edit project, re-paste your .env, Save, then Deploy again.");
    }
}
