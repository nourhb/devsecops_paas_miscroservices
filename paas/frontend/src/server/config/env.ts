import { z } from "zod";

/** First non-empty string among candidates (supports alternate env names). */
function firstNonEmpty(...values: (string | undefined)[]): string {
  for (const v of values) {
    if (v !== undefined && v !== null) {
      const s = String(v).trim();
      if (s !== "") {
        return s;
      }
    }
  }
  return "";
}

const envSchema = z.object({
  /**
   * Set to "true" only for laptops without Jenkins/Sonar/etc. Enterprise production must leave this false.
   */
  DEVSECOPS_ALLOW_SIMULATION: z.enum(["true", "false"]).default("false"),

  DATABASE_URL: z.string().default("postgresql://paas:paas@localhost:5432/paas"),
  JWT_SECRET: z.string().min(32).default("change-this-dev-secret-to-32-char-min"),
  JWT_EXPIRES_IN: z.string().default("2h"),

  JENKINS_BASE_URL: z.string().default(""),
  JENKINS_USERNAME: z.string().default(""),
  JENKINS_API_TOKEN: z.string().default(""),
  /** Optional folder path, e.g. `platform` or `team-a/backend` (multibranch folder jobs). */
  JENKINS_JOB_FOLDER: z.string().default(""),
  /** Query/body parameter name for branch when using buildWithParameters. */
  JENKINS_BRANCH_PARAMETER: z.string().default("BRANCH"),
  /** Use `build` instead of `buildWithParameters` when the job has no parameters. */
  JENKINS_USE_SIMPLE_BUILD: z.enum(["true", "false"]).default("false"),
  /** Which project field matches the Jenkins job name: `projectName` (default) or Prisma `id`. */
  JENKINS_JOB_NAME_SOURCE: z.enum(["projectName", "uuid"]).default("projectName"),
  /** Jenkins job parameter names for deploy (must match the job definition). */
  JENKINS_DEPLOY_GIT_URL_PARAMETER: z.string().default("GIT_URL"),
  JENKINS_DEPLOY_BRANCH_PARAMETER: z.string().default("BRANCH"),
  JENKINS_DEPLOY_IMAGE_NAME_PARAMETER: z.string().default("IMAGE_NAME"),
  JENKINS_DEPLOY_PROJECT_ID_PARAMETER: z.string().default("PROJECT_ID"),
  /** Background deploy monitor: poll interval (ms). */
  JENKINS_DEPLOY_POLL_INTERVAL_MS: z.coerce.number().int().min(1000).default(5000),
  /** Max time to wait for build number + completion (ms). */
  JENKINS_DEPLOY_POLL_MAX_MS: z.coerce.number().int().min(10_000).default(3_600_000),

  HARBOR_BASE_URL: z.string().default(""),
  HARBOR_USERNAME: z.string().default(""),
  HARBOR_PASSWORD: z.string().default(""),
  HARBOR_PROJECT: z.string().default("paas"),
  /**
   * Full image ref for Jenkins IMAGE_NAME, e.g. `harbor.example.com/paas/{{projectName}}`.
   * If empty, built from HARBOR_BASE_URL + HARBOR_PROJECT + project name.
   */
  DEPLOY_IMAGE_NAME_TEMPLATE: z.string().default(""),
  /** Used when Project.branch is empty (Jenkins BRANCH param). */
  DEPLOY_BRANCH_FALLBACK: z.string().default("main"),
  /**
   * If set, stored as Deployment.triggeredById instead of the JWT user (must be an existing User id).
   */
  DEPLOYMENT_TRIGGER_USER_ID: z.string().default(""),

  ARGOCD_BASE_URL: z.string().default(""),
  ARGOCD_AUTH_TOKEN: z.string().default(""),
  ARGOCD_APP_PREFIX: z.string().default("paas"),

  SONAR_BASE_URL: z.string().default(""),
  SONAR_TOKEN: z.string().default(""),

  DEPENDENCY_TRACK_BASE_URL: z.string().default(""),
  DEPENDENCY_TRACK_API_KEY: z.string().default(""),

  PROMETHEUS_BASE_URL: z.string().default(""),
  /** Instant query returning one scalar (0–100) for cluster CPU % (kube-prometheus examples in .env.example). */
  PROMETHEUS_QUERY_CPU: z.string().default(""),
  PROMETHEUS_QUERY_MEMORY: z.string().default(""),

  TRIVY_BASE_URL: z.string().default(""),
  TRIVY_AUTH_TOKEN: z.string().default(""),

  COSIGN_ENFORCE_SIGNED: z.enum(["true", "false"]).default("true"),
  OPA_ENFORCE_SIGNED: z.enum(["true", "false"]).default("true"),
  /** PEM public key for Cosign verify (optional). */
  COSIGN_PUBLIC_KEY: z.string().default(""),
  /** PEM private key for signing (optional; keep out of git). */
  COSIGN_PRIVATE_KEY: z.string().default(""),
  /** Cosign CLI binary name or path (must exist on the server). */
  COSIGN_BINARY_PATH: z.string().default("cosign"),

  /** Full URL for POST { input: { image, signed } } — OPA data document that returns boolean or { allow }. */
  OPA_EVAL_URL: z.string().default(""),

  GITOPS_REPO_URL: z.string().default(""),
  GITOPS_REPO_TOKEN: z.string().default(""),
  GITOPS_DEFAULT_BRANCH: z.string().default("main"),
  /** Path in repo; use {{projectName}} placeholder. */
  GITOPS_VALUES_PATH_PATTERN: z.string().default("apps/{{projectName}}/values.yaml"),
  GITOPS_COMMIT_MESSAGE_TEMPLATE: z.string().default("chore(gitops): bump {{projectName}} to {{imageTag}}"),

  DOCKERHUB_USERNAME: z.string().default(""),
  DOCKERHUB_TOKEN: z.string().default(""),
  DOCKERHUB_NAMESPACE: z.string().default(""),

  KUBERNETES_ENABLED: z.enum(["true", "false"]).default("false"),
  /** Absolute path to kubeconfig; empty uses default (~/.kube/config or in-cluster when applicable). */
  KUBE_CONFIG_PATH: z.string().default(""),

  /** Scheme for generated app URL (no ://). */
  APPS_PUBLIC_URL_SCHEME: z.string().default("https"),
  /** Base domain for app hostnames, e.g. apps.local → https://{subdomain}.apps.local */
  APPS_PUBLIC_BASE_DOMAIN: z.string().default("apps.local"),
  /**
   * If set, used instead of scheme+domain. Placeholders: {{projectName}}, {{subdomain}} (DNS-safe).
   */
  APPS_PUBLIC_URL_TEMPLATE: z.string().default(""),

  /** Timeout (ms) for optional server-side HTTP reachability probe. */
  APPS_REACHABILITY_TIMEOUT_MS: z.coerce.number().int().min(1000).default(8000)
});

const harborUrlRaw = firstNonEmpty(process.env.HARBOR_BASE_URL, process.env.HARBOR_URL);
/** Harbor registry API is not Docker Hub; disable Harbor client when URL points at hub.docker.com. */
const harborBaseEffective = /docker\.com/i.test(harborUrlRaw) ? "" : harborUrlRaw;

function resolveCosignPublicKeyPem(): string {
  const pub = firstNonEmpty(process.env.COSIGN_PUBLIC_KEY);
  if (pub) {
    return pub;
  }
  const maybeMisnamed = firstNonEmpty(process.env.COSIGN_PRIVATE_KEY);
  if (maybeMisnamed.includes("BEGIN PUBLIC KEY")) {
    return maybeMisnamed;
  }
  return "";
}

function resolveCosignPrivateKeyPem(): string {
  const raw = firstNonEmpty(process.env.COSIGN_PRIVATE_KEY);
  if (raw.includes("BEGIN PUBLIC KEY")) {
    return "";
  }
  return raw;
}

const parsed = envSchema.safeParse({
  DEVSECOPS_ALLOW_SIMULATION: process.env.DEVSECOPS_ALLOW_SIMULATION,

  DATABASE_URL: process.env.DATABASE_URL,
  JWT_SECRET: process.env.JWT_SECRET,
  JWT_EXPIRES_IN: process.env.JWT_EXPIRES_IN,

  JENKINS_BASE_URL: firstNonEmpty(process.env.JENKINS_BASE_URL, process.env.JENKINS_URL),
  JENKINS_USERNAME: firstNonEmpty(process.env.JENKINS_USERNAME, process.env.JENKINS_USER),
  JENKINS_API_TOKEN: firstNonEmpty(process.env.JENKINS_API_TOKEN, process.env.JENKINS_TOKEN),
  JENKINS_JOB_FOLDER: process.env.JENKINS_JOB_FOLDER,
  JENKINS_BRANCH_PARAMETER: process.env.JENKINS_BRANCH_PARAMETER,
  JENKINS_USE_SIMPLE_BUILD: process.env.JENKINS_USE_SIMPLE_BUILD,
  JENKINS_JOB_NAME_SOURCE: process.env.JENKINS_JOB_NAME_SOURCE,
  JENKINS_DEPLOY_GIT_URL_PARAMETER: process.env.JENKINS_DEPLOY_GIT_URL_PARAMETER,
  JENKINS_DEPLOY_BRANCH_PARAMETER: process.env.JENKINS_DEPLOY_BRANCH_PARAMETER,
  JENKINS_DEPLOY_IMAGE_NAME_PARAMETER: process.env.JENKINS_DEPLOY_IMAGE_NAME_PARAMETER,
  JENKINS_DEPLOY_PROJECT_ID_PARAMETER: process.env.JENKINS_DEPLOY_PROJECT_ID_PARAMETER,
  JENKINS_DEPLOY_POLL_INTERVAL_MS: process.env.JENKINS_DEPLOY_POLL_INTERVAL_MS,
  JENKINS_DEPLOY_POLL_MAX_MS: process.env.JENKINS_DEPLOY_POLL_MAX_MS,

  HARBOR_BASE_URL: harborBaseEffective,
  HARBOR_USERNAME: process.env.HARBOR_USERNAME,
  HARBOR_PASSWORD: process.env.HARBOR_PASSWORD,
  HARBOR_PROJECT: process.env.HARBOR_PROJECT,
  DEPLOY_IMAGE_NAME_TEMPLATE: process.env.DEPLOY_IMAGE_NAME_TEMPLATE,
  DEPLOY_BRANCH_FALLBACK: process.env.DEPLOY_BRANCH_FALLBACK,
  DEPLOYMENT_TRIGGER_USER_ID: process.env.DEPLOYMENT_TRIGGER_USER_ID,

  ARGOCD_BASE_URL: firstNonEmpty(process.env.ARGOCD_BASE_URL, process.env.ARGOCD_URL),
  ARGOCD_AUTH_TOKEN: firstNonEmpty(process.env.ARGOCD_AUTH_TOKEN, process.env.ARGOCD_TOKEN),
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

  COSIGN_ENFORCE_SIGNED: process.env.COSIGN_ENFORCE_SIGNED,
  OPA_ENFORCE_SIGNED: process.env.OPA_ENFORCE_SIGNED,
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

  APPS_PUBLIC_URL_SCHEME: process.env.APPS_PUBLIC_URL_SCHEME,
  APPS_PUBLIC_BASE_DOMAIN: process.env.APPS_PUBLIC_BASE_DOMAIN,
  APPS_PUBLIC_URL_TEMPLATE: process.env.APPS_PUBLIC_URL_TEMPLATE,
  APPS_REACHABILITY_TIMEOUT_MS: process.env.APPS_REACHABILITY_TIMEOUT_MS
});

if (!parsed.success) {
  throw new Error(`Invalid environment configuration: ${parsed.error.message}`);
}

export const env = parsed.data;
