import { ApiError } from "@/server/http/errors";
type RateLimitOptions = {
    keyPrefix: string;
    windowMs: number;
    maxRequests: number;
    message?: string;
};
type RateLimitRecord = {
    count: number;
    resetAt: number;
};
const bucket = new Map<string, RateLimitRecord>();
function getClientAddress(request: Request) {
    const forwardedFor = request.headers.get("x-forwarded-for") || "";
    const firstForwarded = forwardedFor.split(",")[0]?.trim();
    const realIp = request.headers.get("x-real-ip")?.trim();
    return firstForwarded || realIp || "unknown";
}
export function enforceRateLimit(request: Request, options: RateLimitOptions) {
    const now = Date.now();
    const key = `${options.keyPrefix}:${getClientAddress(request)}`;
    const existing = bucket.get(key);
    if (!existing || existing.resetAt <= now) {
        bucket.set(key, {
            count: 1,
            resetAt: now + options.windowMs
        });
        return;
    }
    if (existing.count >= options.maxRequests) {
        throw new ApiError(429, options.message || "Too many requests. Please retry later.");
    }
    existing.count += 1;
    bucket.set(key, existing);
}
