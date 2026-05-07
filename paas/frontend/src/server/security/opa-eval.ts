import { env } from "@/server/config/env";
import { IntegrationError } from "@/server/http/errors";
type OpaResponse = {
    result?: boolean | {
        allow?: boolean;
    };
};
export async function evaluateOpaImagePolicy(imageRef: string, signed: boolean): Promise<boolean> {
    if (env.OPA_ENFORCE_SIGNED === "false") {
        return true;
    }
    const url = env.OPA_EVAL_URL.trim();
    if (!url) {
        return true;
    }
    const response = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ input: { image: imageRef, signed } })
    });
    if (!response.ok) {
        const t = await response.text();
        throw new IntegrationError(`OPA request failed (${response.status}): ${t.slice(0, 500)}`);
    }
    const data = (await response.json()) as OpaResponse;
    if (typeof data.result === "boolean") {
        return data.result;
    }
    if (data.result && typeof data.result === "object" && "allow" in data.result) {
        return Boolean((data.result as {
            allow?: boolean;
        }).allow);
    }
    throw new IntegrationError("OPA response missing boolean result or { allow: boolean }.");
}
