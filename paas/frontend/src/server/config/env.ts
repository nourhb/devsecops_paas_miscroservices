import { z } from "zod";
function firstNonEmpty(...values: (string | undefined)[]): string {
    for (const v of values) {
        const s = String(v ?? "").trim();
        if (s) {
            return s;
        }
    }
    return "";
}
function preprocessStrictIntegrations(v: unknown): unknown {
    if (v === undefined || v === null) {
        return undefined;
    }
    const s = String(v).trim().toLowerCase();
    if (s === "" || s === "0" || s === "no" || s === "off" || s === "false") {
        return "false";
    }
    if (s === "1" || s === "yes" || s === "on" || s === "true") {
        return "true";
    }
    return v;
}
type EnvParsed = z.infer<typeof envSchema>;
/**
 * Next.js may inline static `process.env.KEY` reads at build time. Keys built dynamically
 * still read the real container/process environment when the standalone server starts.
 */
function runtimeProcessEnvRaw(keyParts: string[]): string | undefined {
    const key = keyParts.join("");
    if (typeof process === "undefined") {
        return undefined;
    }
    const v = process.env[key];
    return v === undefined ? undefined : String(v);
}
function applyRuntimeIntegrationFlags(data: EnvParsed): EnvParsed {
    let out = data;
    const strictRaw = runtimeProcessEnvRaw(["PAAS_STRICT", "_INTEGRATIONS"]);
    if (strictRaw !== undefined && strictRaw.trim() !== "") {
        const p = preprocessStrictIntegrations(strictRaw);
        if (p === "true" || p === "false") {
            out = { ...out, PAAS_STRICT_INTEGRATIONS: p };
        }
    }
    const syncRaw = runtimeProcessEnvRaw(["JENKINS_SYNC_INLINE_JOB_BEFORE", "_TRIGGER"]);
    if (syncRaw !== undefined && syncRaw.trim() !== "") {
        const t = syncRaw.trim().toLowerCase();
        if (t === "true" || t === "false") {
            out = { ...out, JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER: t };
        }
    }
    return out;
}
const envSchema = z.object({
    NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
    DEVSECOPS_ALLOW_SIMULATION: z.enum(["true", "false"]).default("false"),
    DATABASE_URL: z.string().default("postgresql://postgres:root@localhost:5432/paas"),
    JWT_SECRET: z.string().min(32).default("change-this-dev-secret-to-32-char-min"),
    JWT_EXPIRES_IN: z.string().default("2h"),
    APP_BASE_URL: z.string().default("http://localhost:3000"),
    SMTP_HOST: z.string().default(""),
    SMTP_PORT: z.coerce.number().int().min(1).default(587),
    SMTP_SECURE: z.enum(["true", "false"]).default("false"),
    SMTP_USER: z.string().default(""),
    SMTP_PASS: z.string().default(""),
    MAIL_FROM: z.string().default(""),
    GITHUB_WEBHOOK_SECRET: z.string().default(""),
    GITHUB_WEBHOOK_BUILD_MODE: z.enum(["prompt", "auto"]).default("prompt"),
    JENKINS_BASE_URL: z.string().default(""),
    JENKINS_USERNAME: z.string().default(""),
    JENKINS_API_TOKEN: z.string().default(""),
    JENKINS_JOB_FOLDER: z.string().default(""),
    JENKINS_BUILD_JOB_NAME: z.string().default(""),
    JENKINS_DEPLOY_JOB_NAME: z.string().default(""),
    JENKINS_BRANCH_PARAMETER: z.string().default("BRANCH"),
    JENKINS_USE_SIMPLE_BUILD: z.enum(["true", "false"]).default("false"),
    JENKINS_JOB_NAME_SOURCE: z.enum(["projectName", "uuid"]).default("projectName"),
    JENKINS_DEPLOY_GIT_URL_PARAMETER: z.string().default("GIT_URL"),
    JENKINS_DEPLOY_BRANCH_PARAMETER: z.string().default("BRANCH"),
    JENKINS_DEPLOY_IMAGE_NAME_PARAMETER: z.string().default("IMAGE_NAME"),
    JENKINS_DEPLOY_PROJECT_ID_PARAMETER: z.string().default("PROJECT_ID"),
    JENKINS_DEPLOY_GIT_CREDENTIALS_ID_PARAMETER: z.string().default("GIT_CREDENTIALS_ID"),
    JENKINS_AGENT_LABEL: z.string().default(""),
    JENKINS_AGENT_LABEL_PARAMETER: z.string().default("JENKINS_AGENT_LABEL"),
    JENKINS_DEPLOY_POLL_INTERVAL_MS: z.coerce.number().int().min(1000).default(5000),
    JENKINS_DEPLOY_POLL_MAX_MS: z.coerce.number().int().min(10000).default(3600000),
    JENKINS_HTTP_TIMEOUT_MS: z.coerce.number().int().min(5000).default(120000),
    JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER: z.enum(["true", "false"]).default("false"),
    PAAS_MONOREPO_ROOT: z.string().default(""),
    HARBOR_REGISTRY: z.string().default(""),
    HARBOR_BASE_URL: z.string().default(""),
    HARBOR_USERNAME: z.string().default(""),
    HARBOR_PASSWORD: z.string().default(""),
    HARBOR_PROJECT: z.string().default("paas"),
    HELM_OCI_PROJECT: z.string().default("paas"),
    HELM_OCI_INSECURE: z.enum(["true", "false"]).default("false"),
    HELM_OCI_PLAIN_HTTP: z.enum(["true", "false"]).default("false"),
    ARTIFACTORY_URL: z.string().default(""),
    ARTIFACTORY_REPOSITORY: z.string().default("libs-release-local"),
    ARTIFACTORY_USERNAME: z.string().default(""),
    ARTIFACTORY_PASSWORD: z.string().default(""),
    ARTIFACTORY_ACCESS_TOKEN: z.string().default(""),
    ARTIFACTORY_CREDENTIALS_ID: z.string().default(""),
    COSIGN_CREDENTIALS_ID: z.string().default(""),
    NVD_API_KEY: z.string().default(""),
    DEPLOY_IMAGE_NAME_TEMPLATE: z.string().default(""),
    DEPLOY_BRANCH_FALLBACK: z.string().default("main"),
    DEPLOYMENT_TRIGGER_USER_ID: z.string().default(""),
    BUILD_BACKEND: z.enum(["jenkins", "tekton"]).default("jenkins"),
    BUILD_TEMPLATE_VERSION: z.string().default("v1"),
    BUILD_REGISTRY_MIRROR: z.string().default(""),
    BUILD_PACKAGE_PROXY_URL: z.string().default(""),
    BUILD_NPM_REGISTRY: z.string().default(""),
    BUILD_ENFORCE_ARTIFACT_DIGEST: z.enum(["true", "false"]).default("false"),
    TEKTON_API_VERSION: z.string().default("v1beta1"),
    TEKTON_NAMESPACE: z.string().default("tekton-pipelines"),
    TEKTON_SERVICE_ACCOUNT: z.string().default("paas-build-bot"),
    TEKTON_NODE_PIPELINE_NAME: z.string().default("paas-node-build"),
    TEKTON_DEFAULT_PIPELINE_NAME: z.string().default("paas-generic-build"),
    TEKTON_POLL_INTERVAL_MS: z.coerce.number().int().min(1000).default(5000),
    TEKTON_POLL_MAX_MS: z.coerce.number().int().min(10000).default(3600000),
    ARGOCD_BASE_URL: z.string().default(""),
    ARGOCD_AUTH_TOKEN: z.string().default(""),
    ARGOCD_TLS_SKIP_VERIFY: z.enum(["true", "false"]).default("false"),
    ARGOCD_APP_PREFIX: z.string().default("paas"),
    SONAR_BASE_URL: z.string().default(""),
    SONAR_TOKEN: z.string().default(""),
    DEPENDENCY_TRACK_BASE_URL: z.string().default(""),
    DEPENDENCY_TRACK_API_KEY: z.string().default(""),
    PROMETHEUS_BASE_URL: z.string().default(""),
    PROMETHEUS_QUERY_CPU: z.string().default(""),
    PROMETHEUS_QUERY_MEMORY: z.string().default(""),
    TRIVY_BASE_URL: z.string().default(""),
    TRIVY_AUTH_TOKEN: z.string().default(""),
    ZAP_TARGET_URL: z.string().default(""),
    COSIGN_ENFORCE_SIGNED: z.enum(["true", "false"]).default("true"),
    OPA_ENFORCE_SIGNED: z.enum(["true", "false"]).default("true"),
    POLICY_ENGINE: z.enum(["kyverno", "opa", "gatekeeper", "none"]).default("kyverno"),
    KYVERNO_POLICIES_ENABLED: z.enum(["true", "false"]).default("true"),
    COSIGN_PUBLIC_KEY: z.string().default(""),
    COSIGN_PRIVATE_KEY: z.string().default(""),
    COSIGN_BINARY_PATH: z.string().default("cosign"),
    OPA_EVAL_URL: z.string().default(""),
    GITOPS_REPO_URL: z.string().default(""),
    GITOPS_REPO_TOKEN: z.string().default(""),
    GITOPS_DEFAULT_BRANCH: z.string().default("main"),
    GITOPS_VALUES_PATH_PATTERN: z.string().default("apps/{{projectName}}/values.yaml"),
    GITOPS_COMMIT_MESSAGE_TEMPLATE: z.string().default("chore(gitops): bump {{projectName}} to {{imageTag}}"),
    DOCKERHUB_USERNAME: z.string().default(""),
    DOCKERHUB_TOKEN: z.string().default(""),
    DOCKERHUB_NAMESPACE: z.string().default(""),
    KUBERNETES_ENABLED: z.enum(["true", "false"]).default("false"),
    KUBE_CONFIG_PATH: z.string().default(""),
    KUBE_TLS_SKIP_VERIFY: z.enum(["true", "false"]).default("false"),
    INTEGRATIONS_TLS_SKIP_VERIFY: z.enum(["true", "false"]).default("false"),
    APPS_PUBLIC_URL_SCHEME: z.string().default("https"),
    APPS_PUBLIC_BASE_DOMAIN: z.string().default("apps.local"),
    APPS_PUBLIC_URL_TEMPLATE: z.string().default(""),
    APPS_REACHABILITY_TIMEOUT_MS: z.coerce.number().int().min(1000).default(8000),
    AUTH_ALLOW_UNVERIFIED_LOGIN: z.enum(["true", "false"]).default("false"),
    PAAS_STRICT_INTEGRATIONS: z.preprocess(preprocessStrictIntegrations, z.enum(["true", "false"]).default("false")),
    KEYCLOAK_ENABLED: z.enum(["true", "false"]).default("false"),
    KEYCLOAK_ISSUER: z.string().default(""),
    KEYCLOAK_CLIENT_ID: z.string().default(""),
    KEYCLOAK_CLIENT_SECRET: z.string().default(""),
    /** If set (e.g. paas-admin), users whose access token includes this realm role become ADMIN (see Keycloak realm roles). */
    KEYCLOAK_ADMIN_ROLE: z.string().default("")
});
const harborUrlRaw = firstNonEmpty(process.env.HARBOR_BASE_URL, process.env.HARBOR_URL);
const harborBaseEffective = /docker\.com/i.test(harborUrlRaw) ? "" : harborUrlRaw;
function harborRegistryHostFromBase(): string {
    const base = harborBaseEffective.trim();
    if (!base) {
        return "";
    }
    return base
        .replace(/^https?:\/\//i, "")
        .replace(/\/$/, "")
        .split("/")[0];
}
function resolvedHarborRegistryHost(): string {
    const explicit = firstNonEmpty(process.env.HARBOR_REGISTRY);
    if (explicit) {
        return explicit
            .replace(/^https?:\/\//i, "")
            .replace(/\/$/, "")
            .split("/")[0];
    }
    return harborRegistryHostFromBase();
}
function pemFromEnv(raw: string): string {
    return String(raw)
        .trim()
        .replace(/\\n/g, "\n")
        .trim();
}
function resolveCosignPublicKeyPem(): string {
    const pub = firstNonEmpty(process.env.COSIGN_PUBLIC_KEY);
    if (pub) {
        return pemFromEnv(pub);
    }
    const priv = firstNonEmpty(process.env.COSIGN_PRIVATE_KEY);
    if (priv.includes("BEGIN PUBLIC KEY")) {
        return pemFromEnv(priv);
    }
    return "";
}
function resolveCosignPrivateKeyPem(): string {
    const raw = firstNonEmpty(process.env.COSIGN_PRIVATE_KEY);
    if (raw.includes("BEGIN PUBLIC KEY")) {
        return "";
    }
    return raw ? pemFromEnv(raw) : "";
}
function duringNextBuild(): boolean {
    return process.env["NEXT_PHASE"] === "phase-production-build";
}
function collectProductionEnvErrors(parsedEnv: z.infer<typeof envSchema>) {
    const errors: string[] = [];
    if (parsedEnv.NODE_ENV !== "production") {
        return errors;
    }
    if (duringNextBuild()) {
        return errors;
    }
    if (parsedEnv.AUTH_ALLOW_UNVERIFIED_LOGIN === "true") {
        errors.push("AUTH_ALLOW_UNVERIFIED_LOGIN off for prod");
    }
    if (parsedEnv.DEVSECOPS_ALLOW_SIMULATION === "true") {
        errors.push("DEVSECOPS_ALLOW_SIMULATION off for prod");
    }
    if (parsedEnv.DATABASE_URL === "postgresql://postgres:root@localhost:5432/paas") {
        errors.push("DATABASE_URL still default");
    }
    if (parsedEnv.JWT_SECRET === "change-this-dev-secret-to-32-char-min") {
        errors.push("JWT_SECRET still default");
    }
    if (!parsedEnv.JENKINS_BASE_URL || !parsedEnv.JENKINS_USERNAME || !parsedEnv.JENKINS_API_TOKEN) {
        errors.push("need Jenkins URL + user + token");
    }
    if (parsedEnv.PAAS_STRICT_INTEGRATIONS === "true") {
        if (!parsedEnv.ARGOCD_BASE_URL || !parsedEnv.ARGOCD_AUTH_TOKEN) {
            errors.push("need Argo URL + token (or set PAAS_STRICT_INTEGRATIONS=false for Jenkins-only prod)");
        }
        if (parsedEnv.ARGOCD_TLS_SKIP_VERIFY === "true") {
            errors.push("ARGOCD_TLS_SKIP_VERIFY=true is disallowed when PAAS_STRICT_INTEGRATIONS=true in prod; use a verified TLS cert, or set PAAS_STRICT_INTEGRATIONS=false for lab/Jenkins-only");
        }
        if (!parsedEnv.GITOPS_REPO_URL || !parsedEnv.GITOPS_REPO_TOKEN) {
            errors.push("need gitops repo URL + token (or set PAAS_STRICT_INTEGRATIONS=false)");
        }
    }
    if (parsedEnv.KEYCLOAK_ENABLED === "true") {
        const issuer = parsedEnv.KEYCLOAK_ISSUER.trim();
        const cid = parsedEnv.KEYCLOAK_CLIENT_ID.trim();
        const secret = parsedEnv.KEYCLOAK_CLIENT_SECRET.trim();
        if (!issuer || !cid || !secret) {
            errors.push("KEYCLOAK_ENABLED requires KEYCLOAK_ISSUER, KEYCLOAK_CLIENT_ID, and KEYCLOAK_CLIENT_SECRET");
        }
    }
    return errors;
}
const parsed = envSchema.safeParse({
    NODE_ENV: process.env.NODE_ENV,
    DEVSECOPS_ALLOW_SIMULATION: process.env.DEVSECOPS_ALLOW_SIMULATION,
    DATABASE_URL: process.env.DATABASE_URL,
    JWT_SECRET: process.env.JWT_SECRET,
    JWT_EXPIRES_IN: process.env.JWT_EXPIRES_IN,
    APP_BASE_URL: process.env.APP_BASE_URL,
    SMTP_HOST: process.env.SMTP_HOST,
    SMTP_PORT: process.env.SMTP_PORT,
    SMTP_SECURE: process.env.SMTP_SECURE,
    SMTP_USER: process.env.SMTP_USER,
    SMTP_PASS: process.env.SMTP_PASS,
    MAIL_FROM: process.env.MAIL_FROM,
    GITHUB_WEBHOOK_SECRET: process.env.GITHUB_WEBHOOK_SECRET,
    GITHUB_WEBHOOK_BUILD_MODE: process.env.GITHUB_WEBHOOK_BUILD_MODE,
    JENKINS_BASE_URL: firstNonEmpty(process.env.JENKINS_BASE_URL, process.env.JENKINS_URL),
    JENKINS_USERNAME: firstNonEmpty(process.env.JENKINS_USERNAME, process.env.JENKINS_USER),
    JENKINS_API_TOKEN: firstNonEmpty(process.env.JENKINS_API_TOKEN, process.env.JENKINS_TOKEN),
    JENKINS_JOB_FOLDER: process.env.JENKINS_JOB_FOLDER,
    JENKINS_BUILD_JOB_NAME: process.env.JENKINS_BUILD_JOB_NAME,
    JENKINS_DEPLOY_JOB_NAME: process.env.JENKINS_DEPLOY_JOB_NAME,
    JENKINS_BRANCH_PARAMETER: process.env.JENKINS_BRANCH_PARAMETER,
    JENKINS_USE_SIMPLE_BUILD: process.env.JENKINS_USE_SIMPLE_BUILD,
    JENKINS_JOB_NAME_SOURCE: process.env.JENKINS_JOB_NAME_SOURCE,
    JENKINS_DEPLOY_GIT_URL_PARAMETER: process.env.JENKINS_DEPLOY_GIT_URL_PARAMETER,
    JENKINS_DEPLOY_BRANCH_PARAMETER: process.env.JENKINS_DEPLOY_BRANCH_PARAMETER,
    JENKINS_DEPLOY_IMAGE_NAME_PARAMETER: process.env.JENKINS_DEPLOY_IMAGE_NAME_PARAMETER,
    JENKINS_DEPLOY_PROJECT_ID_PARAMETER: process.env.JENKINS_DEPLOY_PROJECT_ID_PARAMETER,
    JENKINS_DEPLOY_GIT_CREDENTIALS_ID_PARAMETER: process.env.JENKINS_DEPLOY_GIT_CREDENTIALS_ID_PARAMETER,
    JENKINS_AGENT_LABEL: process.env.JENKINS_AGENT_LABEL,
    JENKINS_AGENT_LABEL_PARAMETER: process.env.JENKINS_AGENT_LABEL_PARAMETER,
    JENKINS_DEPLOY_POLL_INTERVAL_MS: process.env.JENKINS_DEPLOY_POLL_INTERVAL_MS,
    JENKINS_DEPLOY_POLL_MAX_MS: process.env.JENKINS_DEPLOY_POLL_MAX_MS,
    JENKINS_HTTP_TIMEOUT_MS: process.env.JENKINS_HTTP_TIMEOUT_MS,
    JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER: process.env.JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER,
    PAAS_MONOREPO_ROOT: process.env.PAAS_MONOREPO_ROOT,
    HARBOR_REGISTRY: resolvedHarborRegistryHost(),
    HARBOR_BASE_URL: harborBaseEffective,
    HARBOR_USERNAME: process.env.HARBOR_USERNAME,
    HARBOR_PASSWORD: process.env.HARBOR_PASSWORD,
    HARBOR_PROJECT: process.env.HARBOR_PROJECT,
    HELM_OCI_PROJECT: firstNonEmpty(process.env.HELM_OCI_PROJECT, process.env.HARBOR_PROJECT, "paas"),
    HELM_OCI_INSECURE: process.env.HELM_OCI_INSECURE === "true" ? "true" : "false",
    HELM_OCI_PLAIN_HTTP: process.env.HELM_OCI_PLAIN_HTTP === "true" ? "true" : "false",
    ARTIFACTORY_URL: firstNonEmpty(process.env.ARTIFACTORY_URL, process.env.ARTIFACTORY_BASE_URL),
    ARTIFACTORY_REPOSITORY: firstNonEmpty(process.env.ARTIFACTORY_REPOSITORY, "libs-release-local"),
    ARTIFACTORY_USERNAME: process.env.ARTIFACTORY_USERNAME,
    ARTIFACTORY_PASSWORD: process.env.ARTIFACTORY_PASSWORD,
    ARTIFACTORY_ACCESS_TOKEN: firstNonEmpty(process.env.ARTIFACTORY_ACCESS_TOKEN, process.env.ARTIFACTORY_TOKEN),
    ARTIFACTORY_CREDENTIALS_ID: process.env.ARTIFACTORY_CREDENTIALS_ID,
    COSIGN_CREDENTIALS_ID: process.env.COSIGN_CREDENTIALS_ID,
    NVD_API_KEY: process.env.NVD_API_KEY,
    DEPLOY_IMAGE_NAME_TEMPLATE: process.env.DEPLOY_IMAGE_NAME_TEMPLATE,
    DEPLOY_BRANCH_FALLBACK: process.env.DEPLOY_BRANCH_FALLBACK,
    DEPLOYMENT_TRIGGER_USER_ID: process.env.DEPLOYMENT_TRIGGER_USER_ID,
    BUILD_BACKEND: process.env.BUILD_BACKEND,
    BUILD_TEMPLATE_VERSION: process.env.BUILD_TEMPLATE_VERSION,
    BUILD_REGISTRY_MIRROR: process.env.BUILD_REGISTRY_MIRROR,
    BUILD_PACKAGE_PROXY_URL: process.env.BUILD_PACKAGE_PROXY_URL,
    BUILD_NPM_REGISTRY: process.env.BUILD_NPM_REGISTRY,
    BUILD_ENFORCE_ARTIFACT_DIGEST: process.env.BUILD_ENFORCE_ARTIFACT_DIGEST,
    TEKTON_API_VERSION: process.env.TEKTON_API_VERSION,
    TEKTON_NAMESPACE: process.env.TEKTON_NAMESPACE,
    TEKTON_SERVICE_ACCOUNT: process.env.TEKTON_SERVICE_ACCOUNT,
    TEKTON_NODE_PIPELINE_NAME: process.env.TEKTON_NODE_PIPELINE_NAME,
    TEKTON_DEFAULT_PIPELINE_NAME: process.env.TEKTON_DEFAULT_PIPELINE_NAME,
    TEKTON_POLL_INTERVAL_MS: process.env.TEKTON_POLL_INTERVAL_MS,
    TEKTON_POLL_MAX_MS: process.env.TEKTON_POLL_MAX_MS,
    ARGOCD_BASE_URL: firstNonEmpty(process.env.ARGOCD_BASE_URL, process.env.ARGOCD_URL),
    ARGOCD_AUTH_TOKEN: firstNonEmpty(process.env.ARGOCD_AUTH_TOKEN, process.env.ARGOCD_TOKEN),
    ARGOCD_TLS_SKIP_VERIFY: process.env.ARGOCD_TLS_SKIP_VERIFY,
    ARGOCD_APP_PREFIX: process.env.ARGOCD_APP_PREFIX,
    SONAR_BASE_URL: firstNonEmpty(process.env.SONAR_BASE_URL, process.env.SONAR_URL),
    SONAR_TOKEN: process.env.SONAR_TOKEN,
    DEPENDENCY_TRACK_BASE_URL: process.env.DEPENDENCY_TRACK_BASE_URL,
    DEPENDENCY_TRACK_API_KEY: process.env.DEPENDENCY_TRACK_API_KEY,
    PROMETHEUS_BASE_URL: process.env.PROMETHEUS_BASE_URL,
    PROMETHEUS_QUERY_CPU: process.env.PROMETHEUS_QUERY_CPU,
    PROMETHEUS_QUERY_MEMORY: process.env.PROMETHEUS_QUERY_MEMORY,
    TRIVY_BASE_URL: process.env.TRIVY_BASE_URL,
    TRIVY_AUTH_TOKEN: process.env.TRIVY_AUTH_TOKEN,
    ZAP_TARGET_URL: process.env.ZAP_TARGET_URL,
    COSIGN_ENFORCE_SIGNED: process.env.COSIGN_ENFORCE_SIGNED,
    OPA_ENFORCE_SIGNED: process.env.OPA_ENFORCE_SIGNED,
    POLICY_ENGINE: process.env.POLICY_ENGINE,
    KYVERNO_POLICIES_ENABLED: process.env.KYVERNO_POLICIES_ENABLED,
    COSIGN_PUBLIC_KEY: resolveCosignPublicKeyPem(),
    COSIGN_PRIVATE_KEY: resolveCosignPrivateKeyPem(),
    COSIGN_BINARY_PATH: process.env.COSIGN_BINARY_PATH,
    OPA_EVAL_URL: process.env.OPA_EVAL_URL,
    GITOPS_REPO_URL: firstNonEmpty(process.env.GITOPS_REPO_URL, process.env.GITOPS_REPO),
    GITOPS_REPO_TOKEN: process.env.GITOPS_REPO_TOKEN,
    GITOPS_DEFAULT_BRANCH: process.env.GITOPS_DEFAULT_BRANCH,
    GITOPS_VALUES_PATH_PATTERN: process.env.GITOPS_VALUES_PATH_PATTERN,
    GITOPS_COMMIT_MESSAGE_TEMPLATE: process.env.GITOPS_COMMIT_MESSAGE_TEMPLATE,
    DOCKERHUB_USERNAME: firstNonEmpty(process.env.DOCKERHUB_USERNAME, process.env.HARBOR_USERNAME),
    DOCKERHUB_TOKEN: firstNonEmpty(process.env.DOCKERHUB_TOKEN, process.env.HARBOR_PASSWORD),
    DOCKERHUB_NAMESPACE: firstNonEmpty(process.env.DOCKERHUB_NAMESPACE, process.env.HARBOR_USERNAME),
    KUBERNETES_ENABLED: process.env.KUBERNETES_ENABLED,
    KUBE_CONFIG_PATH: process.env.KUBE_CONFIG_PATH,
    KUBE_TLS_SKIP_VERIFY: process.env.KUBE_TLS_SKIP_VERIFY,
    INTEGRATIONS_TLS_SKIP_VERIFY: process.env.INTEGRATIONS_TLS_SKIP_VERIFY,
    APPS_PUBLIC_URL_SCHEME: process.env.APPS_PUBLIC_URL_SCHEME,
    APPS_PUBLIC_BASE_DOMAIN: process.env.APPS_PUBLIC_BASE_DOMAIN,
    APPS_PUBLIC_URL_TEMPLATE: process.env.APPS_PUBLIC_URL_TEMPLATE,
    APPS_REACHABILITY_TIMEOUT_MS: process.env.APPS_REACHABILITY_TIMEOUT_MS,
    AUTH_ALLOW_UNVERIFIED_LOGIN: process.env.AUTH_ALLOW_UNVERIFIED_LOGIN,
    PAAS_STRICT_INTEGRATIONS: process.env.PAAS_STRICT_INTEGRATIONS,
    KEYCLOAK_ENABLED: process.env.KEYCLOAK_ENABLED,
    KEYCLOAK_ISSUER: process.env.KEYCLOAK_ISSUER,
    KEYCLOAK_CLIENT_ID: process.env.KEYCLOAK_CLIENT_ID,
    KEYCLOAK_CLIENT_SECRET: process.env.KEYCLOAK_CLIENT_SECRET,
    KEYCLOAK_ADMIN_ROLE: process.env.KEYCLOAK_ADMIN_ROLE
});
if (!parsed.success) {
    throw new Error(`env: ${parsed.error.message}`);
}
const envData = applyRuntimeIntegrationFlags(parsed.data);
const productionErrors = collectProductionEnvErrors(envData);
if (productionErrors.length > 0) {
    throw new Error(`prod env: ${productionErrors.join(" \u00B7 ")}`);
}
export const env = envData;
