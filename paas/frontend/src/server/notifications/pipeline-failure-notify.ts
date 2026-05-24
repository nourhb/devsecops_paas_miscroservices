import type { DeploymentFailureReason } from "@prisma/client";
import { env } from "@/server/config/env";
import { sendAuthMail, getAppBaseUrl } from "@/server/auth/auth-mailer";
import { humanizeFailureReason } from "@/server/services/deployment-failure-labels";
const LOG_SNIPPET_MAX = 4500;
function howToInvestigate(reason: DeploymentFailureReason | null): string {
    switch (reason) {
        case "JENKINS":
            return "Open the deployment in the control plane and read the console tail; compare with the Jenkins classic log for the same build number. Typical causes: compile error, missing credentials, SCM checkout failure, or a gated stage (Sonar/Trivy) failing.";
        case "GITOPS":
            return "Confirm GITOPS_REPO_URL and token can push to the values branch; check for merge conflicts and branch protection blocking the bot user.";
        case "ARGOCD":
            return "Open Argo CD for this app: sync errors often mean invalid manifests, missing image pull secret, or RBAC on the destination cluster.";
        case "IMAGE_REF":
            return "Verify the image name/tag Jenkins produced matches what Helm values expect and that the registry is reachable from the cluster.";
        case "TRIGGER":
            return "The deploy trigger did not reach Jenkins or returned an error early—check JENKINS_* env, job folder permissions, and inline pipeline sync if you use Jenkinsfile from the monorepo.";
        case "TIMEOUT":
            return "Increase Jenkins or platform poll windows if the job is legitimately slow; otherwise the controller may be stuck—inspect the running build in Jenkins.";
        case "UNKNOWN":
        default:
            return "Use the deployment detail page for the stored console snippet, then correlate timestamps with cluster events (kubectl describe pod) and integration health on the Platform hub.";
    }
}
export async function notifyPipelineFailureEmail(input: {
    deploymentId: string;
    projectId: string;
    projectName: string;
    ownerEmail: string;
    ownerName: string;
    triggeredByEmail: string | null;
    reason: DeploymentFailureReason | null;
    message: string;
    logs: string;
}): Promise<void> {
    if (env.NOTIFY_PIPELINE_FAILURE_EMAILS !== "true") {
        return;
    }
    const base = getAppBaseUrl();
    const detailUrl = `${base}/deployments/${encodeURIComponent(input.deploymentId)}`;
    const pipelineUrl = `${base}/pipeline/${encodeURIComponent(input.projectId)}`;
    const stage = humanizeFailureReason(input.reason) || "Unknown stage";
    const summary = `Pipeline / deployment failed for project "${input.projectName}" (${stage}).`;
    const logTail = input.logs.length <= LOG_SNIPPET_MAX ? input.logs : `${input.logs.slice(-LOG_SNIPPET_MAX)}\n…(truncated)`;
    const investigation = howToInvestigate(input.reason);
    const cc = input.triggeredByEmail && input.triggeredByEmail.toLowerCase() !== input.ownerEmail.toLowerCase()
        ? input.triggeredByEmail
        : undefined;
    const text = [
        `alertname: PaasPipelineFailure`,
        `severity: critical`,
        `status: firing`,
        ``,
        `summary: ${summary}`,
        ``,
        `description:`,
        input.message || "(no short message stored)",
        ``,
        `stage: ${stage}`,
        `project: ${input.projectName}`,
        `deployment_id: ${input.deploymentId}`,
        ``,
        `what_failed:`,
        `The platform recorded this failure while running your delivery pipeline (build, GitOps, Argo CD, or related gates). The line above is the primary error context we stored.`,
        ``,
        `how_to_fix / next_steps:`,
        investigation,
        ``,
        `links:`,
        `  deployment: ${detailUrl}`,
        `  pipeline: ${pipelineUrl}`,
        ``,
        `console_tail (last bytes):`,
        logTail.trim() || "(no log tail captured yet)",
        ``,
        `— DevSecOps PaaS (notification style inspired by Alertmanager)`,
    ].join("\n");
    const html = `<pre style="font-family:ui-monospace,monospace;font-size:12px;line-height:1.45;white-space:pre-wrap;background:#0b1020;color:#e2e8f0;padding:16px;border-radius:8px;border:1px solid #334155">${escapeHtml(text)}</pre>`;
    await sendAuthMail({
        to: input.ownerEmail,
        cc,
        subject: `[FIRING] Pipeline failed: ${input.projectName} — ${stage}`,
        text,
        html,
    });
}
function escapeHtml(s: string): string {
    return s
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
}
