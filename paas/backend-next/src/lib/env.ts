import { z } from "zod";

const envSchema = z.object({
  JWT_SECRET: z.string().min(32).default("change-this-dev-secret-to-32-char-min"),
  JWT_EXPIRES_IN: z.string().default("2h"),
  JENKINS_URL: z.string().optional(),
  HARBOR_URL: z.string().optional(),
  ARGOCD_URL: z.string().optional(),
  SONAR_URL: z.string().optional(),
  PROMETHEUS_URL: z.string().optional(),
  TRIVY_BASE_URL: z.string().optional(),
  OPA_BASE_URL: z.string().optional(),
  OPA_URL: z.string().optional(),
  PROMETHEUS_BASE_URL: z.string().optional(),
  GRAFANA_URL: z.string().optional(),
  GRAFANA_BASE_URL: z.string().optional(),
  KUBERNETES_API: z.string().optional(),
  COSIGN_PRIVATE_KEY: z.string().optional(),
  GITOPS_REPO: z.string().optional()
});

const parsed = envSchema.safeParse(process.env);
if (!parsed.success) {
  throw new Error(`Invalid environment configuration: ${parsed.error.message}`);
}

const REQUIRED_AT_STARTUP = [
  "DATABASE_URL",
  "JENKINS_URL",
  "JENKINS_USER",
  "JENKINS_TOKEN",
  "HARBOR_URL",
  "HARBOR_USERNAME",
  "HARBOR_PASSWORD",
  "ARGOCD_URL",
  "ARGOCD_TOKEN",
  "GRAFANA_URL",
  "SONAR_URL",
  "COSIGN_PRIVATE_KEY",
  "GITOPS_REPO"
] as const;

const missing = REQUIRED_AT_STARTUP.filter((key) => !process.env[key]);
// Skip during Next.js build (e.g. Docker build) when env vars are not available
const skipValidation =
  process.env.SKIP_ENV_VALIDATION === "1" ||
  process.env.NEXT_PHASE === "phase-production-build";
if (!skipValidation && missing.length > 0) {
  throw new Error(
    `Missing required environment variables: ${missing.join(", ")}`
  );
}

export const env = parsed.data;
