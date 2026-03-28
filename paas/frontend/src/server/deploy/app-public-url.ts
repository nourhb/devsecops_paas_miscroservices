import { env } from "@/server/config/env";

/** DNS-safe subdomain from project display name. */
export function appSubdomainFromProjectName(projectName: string): string {
  return (
    projectName
      .toLowerCase()
      .replace(/[^a-z0-9-]/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "") || "app"
  );
}

/**
 * Public browser URL for the deployed app.
 * Default: {APPS_PUBLIC_URL_SCHEME}://{subdomain}.{APPS_PUBLIC_BASE_DOMAIN}
 * Override with APPS_PUBLIC_URL_TEMPLATE and {{projectName}} / {{subdomain}}.
 */
export function buildAppPublicUrl(projectName: string): string {
  const template = env.APPS_PUBLIC_URL_TEMPLATE.trim();
  const subdomain = appSubdomainFromProjectName(projectName);
  if (template) {
    return template
      .replace(/\{\{projectName\}\}/gi, projectName)
      .replace(/\{\{subdomain\}\}/gi, subdomain);
  }

  let scheme = env.APPS_PUBLIC_URL_SCHEME.trim().toLowerCase() || "https";
  scheme = scheme.replace(/:$/, "").replace(/\/$/, "");
  const domain = env.APPS_PUBLIC_BASE_DOMAIN.trim().replace(/^\./, "").replace(/\/$/, "");
  return `${scheme}://${subdomain}.${domain}`;
}
