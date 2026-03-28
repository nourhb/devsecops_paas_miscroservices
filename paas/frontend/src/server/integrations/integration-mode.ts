import { env } from "@/server/config/env";
import { IntegrationError } from "@/server/http/errors";

/**
 * When false (default for enterprise), integrations must be configured and return real data.
 * Set DEVSECOPS_ALLOW_SIMULATION=true only for local development without Jenkins/Sonar/etc.
 */
export function allowSimulation(): boolean {
  return env.DEVSECOPS_ALLOW_SIMULATION === "true";
}

export function requireConfiguredOrSimulate(serviceName: string, configured: boolean): void {
  if (!configured && !allowSimulation()) {
    throw new IntegrationError(
      `${serviceName} is required: set the corresponding environment variables, or set DEVSECOPS_ALLOW_SIMULATION=true only for non-production.`
    );
  }
}
