import { env } from "@/server/config/env";
import { IntegrationError } from "@/server/http/errors";

/**
 * Registry path for the deployable image (no tag), e.g. `harbor.example.com/paas/my-app`.
 * Tag is appended per deploy (typically Jenkins build number).
 */
export function buildDeployImageRepository(projectName: string): string {
  const template = env.DEPLOY_IMAGE_NAME_TEMPLATE.trim();
  if (template) {
    return template
      .replace(/\{\{projectName\}\}/gi, projectName)
      .replace(/\{\{harborProject\}\}/gi, env.HARBOR_PROJECT);
  }

  const host = env.HARBOR_BASE_URL.replace(/^https?:\/\//i, "").replace(/\/$/, "");
  if (!host) {
    throw new IntegrationError(
      "Configure DEPLOY_IMAGE_NAME_TEMPLATE or HARBOR_BASE_URL so the deploy image reference can be built."
    );
  }

  const safeName = projectName
    .toLowerCase()
    .replace(/[^a-z0-9._-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");

  return `${host}/${env.HARBOR_PROJECT}/${safeName || "app"}`;
}
