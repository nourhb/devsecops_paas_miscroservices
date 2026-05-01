import crypto from "node:crypto";
export function createRawAuthToken() {
    return crypto.randomBytes(32).toString("hex");
}
export function hashAuthToken(token: string) {
    return crypto.createHash("sha256").update(token).digest("hex");
}
