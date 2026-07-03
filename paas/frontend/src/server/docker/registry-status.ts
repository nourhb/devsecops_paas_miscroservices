import { env } from "@/server/config/env";
import { dockerHubClient, harborClient } from "@/server/integrations/devsecops-clients";

export type RegistryKind = "harbor" | "dockerhub" | "none";

export type RegistryStatus = {
    kind: RegistryKind;
    configured: boolean;
    verified: boolean;
    message: string;
    registryLabel: string;
    pushButtonLabel: string;
    configHint: string;
};

function harborConfigured(): boolean {
    return Boolean(env.HARBOR_BASE_URL.trim() && env.HARBOR_USERNAME.trim() && env.HARBOR_PASSWORD.trim());
}

function dockerHubConfigured(): boolean {
    return Boolean(env.DOCKERHUB_USERNAME.trim() && env.DOCKERHUB_TOKEN.trim());
}

export async function getRegistryStatus(): Promise<RegistryStatus> {
    if (harborConfigured()) {
        const verify = await harborClient.verifyCredentials();
        const host = env.HARBOR_REGISTRY.trim() || env.HARBOR_BASE_URL.replace(/^https?:\/\//, "").replace(/\/$/, "").split("/")[0];
        return {
            kind: "harbor",
            configured: true,
            verified: verify.ok,
            message: verify.message,
            registryLabel: `Harbor (${host}/${env.HARBOR_PROJECT})`,
            pushButtonLabel: "Push to Harbor",
            configHint: "Harbor is configured via HARBOR_BASE_URL, HARBOR_USERNAME, HARBOR_PASSWORD, and HARBOR_PROJECT. Pushes verify against the Harbor API."
        };
    }
    if (dockerHubConfigured()) {
        const verify = await dockerHubClient.verifyCredentials();
        const ns = env.DOCKERHUB_NAMESPACE.trim() || env.DOCKERHUB_USERNAME.trim();
        return {
            kind: "dockerhub",
            configured: true,
            verified: verify.ok,
            message: verify.message,
            registryLabel: `Docker Hub (${ns})`,
            pushButtonLabel: "Push to Docker Hub",
            configHint: "Docker Hub is configured via DOCKERHUB_USERNAME, DOCKERHUB_TOKEN, and optionally DOCKERHUB_NAMESPACE."
        };
    }
    return {
        kind: "none",
        configured: false,
        verified: false,
        message: "No registry credentials configured.",
        registryLabel: "Not configured",
        pushButtonLabel: "Simulate push",
        configHint: "Set HARBOR_BASE_URL, HARBOR_USERNAME, HARBOR_PASSWORD, and HARBOR_PROJECT for the lab registry, or DOCKERHUB_USERNAME, DOCKERHUB_TOKEN, and DOCKERHUB_NAMESPACE for Docker Hub. Without them, pushes are simulated and still written to history for auditing."
    };
}
