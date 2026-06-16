import type { DeploymentFailureReason } from "@prisma/client";
import { deploymentFailureStageLabel } from "@/lib/deployment-failure-labels";
import type { PipelineHelpAction, PipelineHelpItem, PipelineHelpSeverity } from "@/types";
import { PAAS_DEPLOY_INCREMENTAL_JENKINS_STAGES } from "@/lib/paas-deploy-jenkins-stages";

interface AdviceTemplate {
    happened: string;
    means: string;
    fix: string;
    severity?: PipelineHelpSeverity;
    action?: PipelineHelpAction;
}

function stepLabel(stepNum: number): string {
    const raw = PAAS_DEPLOY_INCREMENTAL_JENKINS_STAGES[stepNum - 1];
    if (!raw) {
        return `Step ${stepNum}`;
    }
    return raw.replace(/^Step \d+ —\s*/, "");
}

function itemId(parts: string[]): string {
    return parts.join(":").toLowerCase().replace(/\s+/g, "-").slice(0, 120);
}

function adviceForJenkinsStep(step: number, id: string, level: string, message: string): AdviceTemplate | null {
    const key = `${step}:${id}`.toLowerCase();
    const byKey: Record<string, AdviceTemplate> = {
        "1:build-env": {
            happened: "Your application settings were not sent to the build.",
            means: "The build can still run, but runtime settings (URLs, API keys) may be missing in the deployed app.",
            fix: "Open Edit project, fill in Application environment, save, then run Full deploy again.",
            severity: "warning",
            action: { label: "Edit project", kind: "edit_project" }
        },
        "1:params": {
            happened: "Project settings were checked before the build started.",
            means: "This is a normal confirmation that Git, branch, and image name look valid.",
            fix: "No action needed.",
            severity: "success"
        },
        "4:dependency-track": {
            happened: "The dependency security report could not be sent to Dependency-Track.",
            means: "Your app was still built, but the security dashboard may not show the latest dependency list.",
            fix: "Ask your platform admin to configure Dependency-Track on Jenkins. You can still use the Security page after the next successful upload.",
            severity: "warning",
            action: { label: "Open Security", kind: "security" }
        },
        "4:sca": {
            happened: "The dependency scan (SCA) step had a problem.",
            means: "The build may have continued, but the list of third-party libraries was not fully analyzed.",
            fix: "Check the build log for missing lockfiles (package-lock.json or yarn.lock). Push an updated lockfile, then rebuild. Your admin may need Docker or an API key on Jenkins.",
            severity: "warning"
        },
        "5:sonar": {
            happened: "The code quality scan (SonarQube) did not finish successfully.",
            means: "Code was still built, but quality and security rules in Sonar were not evaluated for this build.",
            fix: "Ask your admin to set SonarQube URL and token on the platform, then run Full deploy again.",
            severity: level === "FAIL" ? "error" : "warning",
            action: { label: "Open Security", kind: "security" }
        },
        "7:helm_meta": {
            happened: "Release metadata for deployment was not written.",
            means: "The image may still deploy, but some deployment details might be incomplete in artifacts.",
            fix: "If deploy fails later, open the Jenkins console for Step 7 or ask your admin to check Helm packaging.",
            severity: "warning"
        },
        "9:cosign": {
            happened: "The container image was not signed.",
            means: "The app can still run in the lab, but production clusters that require signed images may refuse to deploy it.",
            fix: "Ask your admin to set up Cosign signing (Step 9). This is important before enforcing image signature policies.",
            severity: "warning",
            action: { label: "Open Security", kind: "security" }
        },
        "10:zap": {
            happened: "The automatic website security test (ZAP) was skipped.",
            means: "No dynamic scan ran against your live URL. Hidden web vulnerabilities may not have been checked.",
            fix: "Set your app's public URL in project settings if you want this test. It is optional in the lab.",
            severity: "info",
            action: { label: "Edit project", kind: "edit_project" }
        }
    };
    if (byKey[key]) {
        return byKey[key];
    }
    const msg = message.toLowerCase();
    if (step === 4 && (msg.includes("bom.json") || msg.includes("sbom"))) {
        return {
            happened: "The software bill of materials (list of dependencies) was not created.",
            means: "Security tools use this file to find vulnerable libraries.",
            fix: "Ensure your repo has a lockfile (npm, yarn, or Python requirements). Rebuild after fixing. Admin may need to enable Docker on Jenkins.",
            severity: "warning"
        };
    }
    if (step === 5 && msg.includes("sonar")) {
        return adviceForJenkinsStep(step, "sonar", level, message);
    }
    if (level === "FAIL") {
        return {
            happened: `Step ${step} (${stepLabel(step)}) failed.`,
            means: message || "The pipeline stopped at this step.",
            fix: "Open the Jenkins build log, search for the first red error line, fix your code or settings, then rebuild.",
            severity: "error"
        };
    }
    if (level === "WARN") {
        return {
            happened: `Step ${step} (${stepLabel(step)}) finished with a warning.`,
            means: message || "Something was not ideal but the build may have continued.",
            fix: "Read the technical detail below or ask your admin if you are unsure.",
            severity: "warning"
        };
    }
    if (level === "SKIP") {
        return {
            happened: `Step ${step} (${stepLabel(step)}) was skipped.`,
            means: message || "This step was intentionally skipped for this build.",
            fix: "No action needed unless you expected this step to run.",
            severity: "info"
        };
    }
    return null;
}

function adviceForDeployStep(step: string, status: string, detail: string): AdviceTemplate | null {
    const s = status.toUpperCase();
    const byStep: Record<string, AdviceTemplate> = {
        gitops: {
            happened: "Updating deployment settings in Git failed.",
            means: "The cluster may still be running an older version of your app.",
            fix: "Ask your admin to check GitOps repository access, branch permissions, and merge conflicts. Then run Full deploy again.",
            severity: s === "FAIL" ? "error" : "warning"
        },
        gitops_inactive: {
            happened: "GitOps update for the inactive deployment slot had an issue.",
            means: "Blue/green deployment may not have progressed correctly.",
            fix: "Check deploy logs and GitOps repo. Contact your admin if the error persists.",
            severity: s === "FAIL" ? "error" : "warning"
        },
        argocd_sync: {
            happened: "Argo CD could not sync your app to the cluster.",
            means: "Kubernetes may not have received the latest image or configuration.",
            fix: "Open the Argo CD section on this page. Common causes: invalid YAML, missing image, or cluster permissions.",
            severity: s === "FAIL" ? "error" : "warning"
        },
        argocd_ready: {
            happened: "Your app did not become healthy in the cluster in time.",
            means: "Pods may be crashing, failing health checks, or still starting.",
            fix: "Wait a few minutes and refresh. If it stays unhealthy, check pod logs in Monitoring or ask your admin.",
            severity: s === "FAIL" ? "error" : "warning"
        },
        security_gate: {
            happened: "The security gate blocked deployment.",
            means: detail || "Security requirements (signing, policy, or vulnerabilities) were not met.",
            fix: "Open the Security page to see what failed, fix those items, then run Full deploy again.",
            severity: "error",
            action: { label: "Open Security", kind: "security" }
        },
        url: {
            happened: "Your public app URL could not be verified.",
            means: "The app might still be running, but the link may not work yet.",
            fix: "Check ingress settings in GitOps values and wait for DNS. Open the deployment link from the project page.",
            severity: s === "FAIL" ? "error" : "warning"
        }
    };
    const base = byStep[step.toLowerCase()];
    if (base) {
        return {
            ...base,
            means: detail ? `${base.means} Detail: ${detail}` : base.means
        };
    }
    if (s === "FAIL" || s === "WARN") {
        return {
            happened: `Deploy check "${step}" reported ${status}.`,
            means: detail || "Something went wrong after the Jenkins build.",
            fix: "Read the deploy log on this page or contact your platform admin.",
            severity: s === "FAIL" ? "error" : "warning"
        };
    }
    return null;
}

function failureAdvice(reason: DeploymentFailureReason | null, message: string | null): AdviceTemplate {
    const stage = deploymentFailureStageLabel(reason) || "pipeline";
    const fixes: Record<DeploymentFailureReason, string> = {
        JENKINS: "Open the build log in Jenkins. Look for compile errors, missing passwords, or a failed test step. Fix the error in your code or settings, push to Git, then click Full deploy.",
        GITOPS: "Your admin should verify the GitOps repository URL and token can push changes. Check for merge conflicts on the values file.",
        ARGOCD: "Open Argo CD for this project. Sync errors often mean a bad manifest or the cluster cannot pull the image.",
        IMAGE_REF: "The image name from the build does not match what deployment expects. If the log mentions harbor and nip.io, Jenkins pushed with a different hostname than PaaS — ask your admin to align HARBOR_REGISTRY_HOST (use IP:port, not nip.io). Then rebuild.",
        TRIGGER: "The platform could not start Jenkins. Your admin should check Jenkins URL, API token, and job permissions.",
        TIMEOUT: "The build or deploy took too long. Try again, or ask your admin to increase timeout settings if the job is normally slow.",
        UNKNOWN: "Open the deployment details and build log. Note the last error line and share it with your admin if needed."
    };
    const fix = reason ? fixes[reason] : fixes.UNKNOWN;
    return {
        happened: `The ${stage.toLowerCase()} step failed.`,
        means: message?.trim() || "The platform saved an error message from the last run.",
        fix,
        severity: "error"
    };
}

const RAW_LOG_HINTS: Array<{
    pattern: RegExp;
    happened: string;
    means: string;
    fix: string;
}> = [
    {
        pattern: /does not match expected repository|artifact harbor\./i,
        happened: "The built image address does not match the registry address PaaS expects.",
        means: "Jenkins may have pushed to Harbor using a hostname like harbor.…nip.io while deployment expects 192.168.x.x:port.",
        fix: "Ask your admin to set the same Harbor host everywhere (usually the IP and port, not nip.io). Run Full deploy again after fixing platform env."
    },
    {
        pattern: /\bnpm ERR!|\byarn run\b.*error|ERR!.*exit code/i,
        happened: "Installing or building JavaScript packages failed.",
        means: "Node.js could not compile or install dependencies.",
        fix: "Fix errors in package.json or your source code, commit, push, then rebuild."
    },
    {
        pattern: /\bModule not found\b|Cannot find module/i,
        happened: "The build could not find a required file or package.",
        means: "A dependency is missing or an import path is wrong.",
        fix: "Check import paths and run npm install locally, then push the lockfile."
    },
    {
        pattern: /\b401\b|\b403\b|denied|not authorized|authentication failed/i,
        happened: "A login or permission was rejected.",
        means: "Git, Docker registry, or another service refused access.",
        fix: "Verify Git credentials on the project and ask your admin to check registry tokens."
    },
    {
        pattern: /ImagePullBackOff|ErrImagePull/i,
        happened: "The cluster could not download your container image.",
        means: "The image tag may be wrong or the registry is unreachable.",
        fix: "Confirm the build pushed to Harbor and the tag in deployment matches. Ask your admin if needed."
    },
    {
        pattern: /ENOENT.*[Dd]ockerfile|dockerfile.*not found/i,
        happened: "No Dockerfile was found for this project.",
        means: "The build needs instructions to create a container image.",
        fix: "Add a Dockerfile to your repo or enable auto-generate Dockerfile in Edit project."
    }
];

export function buildHelpFromJenkinsCheck(input: {
    step: number;
    id: string;
    level: string;
    message: string;
}): PipelineHelpItem | null {
    if (input.level === "OK") {
        return null;
    }
    const template = adviceForJenkinsStep(input.step, input.id, input.level, input.message);
    if (!template) {
        return null;
    }
    return {
        id: itemId(["jenkins", String(input.step), input.id, input.level]),
        severity: template.severity ?? (input.level === "FAIL" ? "error" : "warning"),
        stepLabel: stepLabel(input.step),
        happened: template.happened,
        means: template.means,
        fix: template.fix,
        technicalDetail: input.message?.trim() || undefined,
        action: template.action
    };
}

export function buildHelpFromDeployCheck(input: {
    step: string;
    status: string;
    detail: string;
}): PipelineHelpItem | null {
    if (input.status === "OK") {
        return null;
    }
    const template = adviceForDeployStep(input.step, input.status, input.detail);
    if (!template) {
        return null;
    }
    return {
        id: itemId(["deploy", input.step, input.status]),
        severity: template.severity ?? (input.status === "FAIL" ? "error" : "warning"),
        stepLabel: "After build",
        happened: template.happened,
        means: template.means,
        fix: template.fix,
        technicalDetail: input.detail?.trim() || undefined,
        action: template.action
    };
}

export function buildHelpFromFailure(reason: DeploymentFailureReason | null, message: string | null): PipelineHelpItem {
    const template = failureAdvice(reason, message);
    return {
        id: itemId(["failure", reason ?? "unknown"]),
        severity: "error",
        stepLabel: deploymentFailureStageLabel(reason) || "Pipeline",
        happened: template.happened,
        means: template.means,
        fix: template.fix,
        technicalDetail: message?.trim() || undefined
    };
}

export function buildHelpFromRawLogs(logTail: string): PipelineHelpItem[] {
    const tail = logTail.slice(-8000);
    const items: PipelineHelpItem[] = [];
    for (const hint of RAW_LOG_HINTS) {
        if (!hint.pattern.test(tail)) {
            continue;
        }
        items.push({
            id: itemId(["raw", hint.pattern.source.slice(0, 40)]),
            severity: "error",
            happened: hint.happened,
            means: hint.means,
            fix: hint.fix
        });
    }
    return items;
}

export function buildSuccessHelpItem(): PipelineHelpItem {
    return {
        id: "overall-success",
        severity: "success",
        happened: "Your last pipeline run completed successfully.",
        means: "Build, security checks, and deployment steps finished without blocking errors.",
        fix: "No action needed. Open your app from the project or deployment page when you are ready."
    };
}

export function buildNoLogsHelpItem(): PipelineHelpItem {
    return {
        id: "no-logs",
        severity: "info",
        happened: "No build has been analyzed yet.",
        means: "We read the console from your last deployment to give personalized guidance.",
        fix: "Click Full deploy or Trigger build, wait for it to finish, then open Pipeline help again.",
        action: { label: "Run a build", kind: "rebuild" }
    };
}
