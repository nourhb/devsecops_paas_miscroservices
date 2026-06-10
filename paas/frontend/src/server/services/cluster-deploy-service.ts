import { DeploymentFailureReason, DeploymentJobStatus } from "@prisma/client";
import { DEPLOYMENT_LOG_TAIL_MAX_CHARS } from "@/server/constants/deploy";
import { resolveBuildPlan } from "@/server/build-planner";
import { env } from "@/server/config/env";
import { prisma } from "@/server/db/prisma";
import { buildMetadataLines, formatArtifactReference } from "@/server/build-metadata";
import { buildAppPublicUrl } from "@/server/deploy/app-public-url";
import { resolveDeployProfileFromProject } from "@/server/deploy/deploy-profile";
import { probeAppUrlReachability } from "@/server/deploy/deploy-reachability";
import { buildDeployImageRepository } from "@/server/deploy/deploy-image";
import {
    blueGreenDeploymentNameCandidates,
    resolveDeploymentStrategy,
    rollingDeploymentNameCandidates
} from "@/server/gitops/gitops-blue-green";
import { commitHelmValuesGitHub } from "@/server/gitops/gitops-github-service";
import {
    deleteStaleBlueGreenDeployments,
    remediateRollingDeployments,
    waitForAnyDeploymentReady
} from "@/server/integrations/kubernetes-client";
import { augmentBuildEnvForPipeline } from "@/server/projects/project-build-env";
import { resolveBuildEnvFromStorage } from "@/server/projects/project-secrets-crypto";
import { updateProject } from "@/server/projects/project-service";
import { getSecurityMetrics } from "@/server/security/security-service";
import { waitForArgoApplicationReady, syncArgoApplication } from "@/server/services/argocd-service";
import { clearDeploymentFailureFields, recordDeploymentFailure } from "@/server/services/deployment-failure";
import { ensureProjectNamespaceReady } from "@/server/services/namespace-setup-service";

function tail(s: string): string {
    return s.length <= DEPLOYMENT_LOG_TAIL_MAX_CHARS ? s : s.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS);
}

interface PromoteDeploymentInput {
    provider: "jenkins" | "tekton";
    runId: string;
    runNumber: number | null;
    artifactImage: string | null;
    artifactDigest: string | null;
    buildLogTail: string;
}

function blueGreenDeployEnabled(): boolean {
    return resolveDeploymentStrategy(null) === "BlueGreen";
}

async function appendArgoSyncAndWait(
    sections: string[],
    projectName: string,
    destNamespace: string
): Promise<{ argoSyncOk: boolean; shouldAbort: boolean }> {
    let argoSyncOk = false;
    try {
        const argo = await syncArgoApplication(projectName, destNamespace);
        sections.push(argo.logs);
        if (/Sync accepted|Sync triggered|already exists|created/i.test(argo.logs)) {
            sections.push(`PAAS_DEPLOY_VERIFY step=argocd_sync status=OK detail=${argo.logs.replace(/\s+/g, " ").slice(0, 300)}`);
            argoSyncOk = true;
        }
        else if (/WARN/i.test(argo.logs)) {
            sections.push(`PAAS_DEPLOY_VERIFY step=argocd_sync status=WARN detail=${argo.logs.replace(/\s+/g, " ").slice(0, 300)}`);
        }
    }
    catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        const lenientIntegrations = env.PAAS_STRICT_INTEGRATIONS !== "true";
        if (lenientIntegrations) {
            sections.push(`[argocd] WARN: ${msg} — continuing to wait for cluster (PAAS_STRICT_INTEGRATIONS=${env.PAAS_STRICT_INTEGRATIONS}).`);
            sections.push(`PAAS_DEPLOY_VERIFY step=argocd_sync status=WARN detail=${msg.slice(0, 400)}`);
        }
        else {
            sections.push(`[argocd] FAILED: ${msg}`);
            sections.push(`PAAS_DEPLOY_VERIFY step=argocd_sync status=FAIL detail=${msg.slice(0, 400)}`);
            return { argoSyncOk: false, shouldAbort: true };
        }
    }
    if (argoSyncOk || env.PAAS_STRICT_INTEGRATIONS !== "true") {
        const argoWait = await waitForArgoApplicationReady(projectName, { timeoutMs: env.PAAS_DEPLOY_WAIT_ARGO_MS });
        sections.push(argoWait.logs);
        if (argoWait.ready) {
            sections.push("PAAS_DEPLOY_VERIFY step=argocd_ready status=OK detail=Healthy+Synced");
        }
        else if (env.PAAS_STRICT_INTEGRATIONS === "true") {
            sections.push("PAAS_DEPLOY_VERIFY step=argocd_ready status=FAIL detail=timeout");
            return { argoSyncOk, shouldAbort: true };
        }
        else {
            sections.push("PAAS_DEPLOY_VERIFY step=argocd_ready status=WARN detail=timeout");
        }
    }
    return { argoSyncOk, shouldAbort: false };
}

async function reconcileClusterWorkload(
    sections: string[],
    destNamespace: string,
    projectName: string,
    artifactRef: string,
    containerPort: number
): Promise<void> {
    if (env.KUBERNETES_ENABLED !== "true") {
        return;
    }
    const removed = await deleteStaleBlueGreenDeployments(destNamespace);
    if (removed.length > 0) {
        sections.push(`[deploy] removed stale blue/green deployments: ${removed.join(", ")}`);
    }
    const candidates = rollingDeploymentNameCandidates(projectName);
    const patched = await remediateRollingDeployments(destNamespace, candidates, artifactRef, containerPort);
    if (patched.length > 0) {
        const profileNote = containerPort === 80 ? " nginx" : containerPort === 8000 ? " python" : "";
        sections.push(`[deploy] cluster auto-heal image+port=${containerPort}${profileNote} on: ${patched.join(", ")}`);
    }
}

async function waitForRollingWorkload(
    sections: string[],
    destNamespace: string,
    projectName: string,
    timeoutMs: number
): Promise<{ ready: boolean; message: string; deploymentName: string | null }> {
    const candidates = rollingDeploymentNameCandidates(projectName);
    sections.push(`[deploy] waiting for workload (${candidates.join(" | ")}) in ${destNamespace}…`);
    const ready = await waitForAnyDeploymentReady(destNamespace, candidates, timeoutMs);
    sections.push(`[deploy] ${ready.message}`);
    return ready;
}

async function runRollingGitOpsPromote(
    sections: string[],
    projectName: string,
    destNamespace: string,
    artifactRef: string,
    gitopsOptions: { buildProfile: import("@/server/build-planner").BuildProfile; buildEnv: Record<string, string> | null },
    containerPort: number,
    label: string
): Promise<{ argoSyncOk: boolean; shouldAbort: boolean; workloadReady: boolean }> {
    sections.push(`[deploy] strategy=Rolling${label ? ` ${label}` : ""}`);
    const git = await commitHelmValuesGitHub(projectName, artifactRef, {
        ...gitopsOptions,
        forceRolling: true
    });
    sections.push(`[gitops] rolling committed ${git.ref}`);
    sections.push(`PAAS_DEPLOY_VERIFY step=gitops_rolling status=OK detail=${git.ref}`);
    sections.push(`[build-meta] paas_strict_integrations=${env.PAAS_STRICT_INTEGRATIONS}`);
    const argo = await appendArgoSyncAndWait(sections, projectName, destNamespace);
    if (argo.shouldAbort) {
        return { argoSyncOk: argo.argoSyncOk, shouldAbort: true, workloadReady: false };
    }
    await reconcileClusterWorkload(sections, destNamespace, projectName, artifactRef, containerPort);
    let ready = await waitForRollingWorkload(sections, destNamespace, projectName, env.PAAS_BLUE_GREEN_WAIT_DEPLOY_MS);
    if (!ready.ready) {
        sections.push("[deploy] workload not ready — retry cluster reconcile + shorter wait");
        await reconcileClusterWorkload(sections, destNamespace, projectName, artifactRef, containerPort);
        await appendArgoSyncAndWait(sections, projectName, destNamespace);
        ready = await waitForRollingWorkload(
            sections,
            destNamespace,
            projectName,
            Math.max(60000, Math.floor(env.PAAS_BLUE_GREEN_WAIT_DEPLOY_MS / 2))
        );
    }
    if (ready.ready) {
        sections.push(`PAAS_DEPLOY_VERIFY step=workload_ready status=OK detail=${ready.deploymentName ?? "unknown"}`);
    }
    else {
        sections.push(`PAAS_DEPLOY_VERIFY step=workload_ready status=FAIL detail=${ready.message.slice(0, 400)}`);
    }
    const lenient = env.PAAS_STRICT_INTEGRATIONS !== "true";
    return {
        argoSyncOk: argo.argoSyncOk,
        shouldAbort: !ready.ready && !lenient,
        workloadReady: ready.ready
    };
}

async function persistFailure(deploymentId: string, projectId: string, fullLog: string, reason: DeploymentFailureReason, shortMessage: string): Promise<void> {
    const logs = tail(fullLog);
    await recordDeploymentFailure(deploymentId, projectId, {
        reason,
        message: shortMessage,
        logs
    });
}

export async function promoteDeploymentAfterJenkinsSuccess(deploymentId: string, projectId: string, projectName: string, jenkinsBuildNumber: number, jenkinsLogTail: string): Promise<void> {
    await promoteDeploymentAfterBuildSuccess(deploymentId, projectId, projectName, {
        provider: "jenkins",
        runId: String(jenkinsBuildNumber),
        runNumber: jenkinsBuildNumber,
        artifactImage: `${buildDeployImageRepository(projectName)}:${jenkinsBuildNumber}`,
        artifactDigest: null,
        buildLogTail: jenkinsLogTail
    });
}

export async function promoteDeploymentAfterBuildSuccess(deploymentId: string, projectId: string, projectName: string, input: PromoteDeploymentInput): Promise<void> {
    let imageRef = input.artifactImage;
    if (!imageRef) {
        try {
            imageRef =
                input.runNumber === null
                    ? null
                    : `${buildDeployImageRepository(projectName)}:${input.runNumber}`;
        }
        catch (error) {
            const msg = error instanceof Error ? error.message : String(error);
            await persistFailure(deploymentId, projectId, `${input.buildLogTail}\n\n[deploy] Could not build image reference: ${msg}`, DeploymentFailureReason.IMAGE_REF, msg);
            return;
        }
    }
    if (!imageRef) {
        await persistFailure(deploymentId, projectId, `${input.buildLogTail}\n\n[deploy] Build backend completed without an artifact image.`, DeploymentFailureReason.IMAGE_REF, "Build backend completed without an artifact image.");
        return;
    }
    const projectRow = await prisma.project.findUnique({
        where: { id: projectId },
        select: {
            namespace: true,
            language: true,
            gitRepositoryUrl: true,
            autoGenerateDockerfile: true,
            buildEnv: true
        }
    });
    const buildPlan = resolveBuildPlan(projectRow ?? { language: "custom" });
    const deployProfile = resolveDeployProfileFromProject(projectRow ?? {});
    const artifactRef = formatArtifactReference(imageRef, input.artifactDigest) ?? imageRef;
    const buildSection = [
        ...buildMetadataLines({
            provider: input.provider,
            profile: buildPlan.profile,
            mode: buildPlan.mode,
            templateName: buildPlan.templateName,
            templateVersion: buildPlan.templateVersion,
            detectionReason: buildPlan.detectionReason,
            zeroConfig: buildPlan.zeroConfig
        }, {
            runId: input.runId,
            runNumber: input.runNumber,
            artifactImage: imageRef,
            artifactDigest: input.artifactDigest
        }),
        tail(input.buildLogTail)
    ]
        .filter(Boolean)
        .join("\n");
    const buildPart = tail(buildSection);
    const sections: string[] = [
        buildPart,
        "",
        "--- GitOps (Helm values) + Argo CD ---",
        `[image] ${artifactRef}`,
        `[build-profile] ${buildPlan.profile}`,
        `[deploy-profile] port=${deployProfile.containerPort} (${deployProfile.profile})`
    ];
    await prisma.deployment.update({
        where: { id: deploymentId },
        data: { status: DeploymentJobStatus.SUCCESS, logs: buildPart, ...clearDeploymentFailureFields() }
    });
    await updateProject(projectId, {
        lastDeploymentStatus: "SUCCESS",
        deploymentLogs: buildPart,
        buildStatus: "PUSHING",
        imageTag: artifactRef
    });
    if (env.PAAS_ENFORCE_SECURITY_GATE === "true") {
        const security = await getSecurityMetrics(projectId);
        const enforcement = security.securityEnforcement;
        if (!enforcement?.deploymentAllowed) {
            const gateMsg = enforcement?.summary || "Security gate did not pass.";
            sections.push(`[security-gate] BLOCKED: ${gateMsg}`);
            sections.push(`PAAS_DEPLOY_VERIFY step=security_gate status=FAIL detail=${gateMsg.slice(0, 400)}`);
            await persistFailure(deploymentId, projectId, sections.join("\n"), DeploymentFailureReason.UNKNOWN, gateMsg);
            return;
        }
        sections.push(`PAAS_DEPLOY_VERIFY step=security_gate status=OK detail=${(enforcement.summary || "Security gate passed.").slice(0, 300)}`);
    }
    await prisma.deployment.update({
        where: { id: deploymentId },
        data: { status: DeploymentJobStatus.DEPLOYING, ...clearDeploymentFailureFields() }
    });
    await updateProject(projectId, { lastDeploymentStatus: "PROMOTING" });
    await prisma.containerImage.create({
        data: {
            projectId,
            imageRef,
            registry: "harbor",
            action: "PROMOTE",
            digest: input.artifactDigest ?? null,
            logs: buildPart
        }
    }).catch(() => null);
    const destNamespace = projectRow?.namespace?.trim() || projectName.toLowerCase().replace(/[^a-z0-9-]/g, "-");
    const namespacePrep = await ensureProjectNamespaceReady(destNamespace);
    if (namespacePrep.logs) {
        sections.push(namespacePrep.logs);
    }
    for (const warning of namespacePrep.warnings) {
        sections.push(`[k8s] WARN: ${warning}`);
    }
    const gitopsOptions = {
        buildProfile: deployProfile.profile,
        buildEnv: augmentBuildEnvForPipeline(projectName, resolveBuildEnvFromStorage(projectRow?.buildEnv))
    };
    const blueGreen = blueGreenDeployEnabled();
    let argoSyncOk = false;
    let workloadReady = false;
    try {
        if (blueGreen) {
            sections.push("[deploy] strategy=BlueGreen phase=inactive");
            const gitInactive = await commitHelmValuesGitHub(projectName, artifactRef, {
                ...gitopsOptions,
                blueGreenPhase: "inactive"
            });
            sections.push(`[gitops] inactive slot committed ${gitInactive.ref}`);
            sections.push(`PAAS_DEPLOY_VERIFY step=gitops_inactive status=OK detail=${gitInactive.ref}`);
            sections.push(`[build-meta] paas_strict_integrations=${env.PAAS_STRICT_INTEGRATIONS}`);
            const argoInactive = await appendArgoSyncAndWait(sections, projectName, destNamespace);
            if (argoInactive.shouldAbort) {
                await persistFailure(deploymentId, projectId, sections.join("\n"), DeploymentFailureReason.ARGOCD, "Argo CD sync failed during blue-green inactive deploy.");
                return;
            }
            argoSyncOk = argoInactive.argoSyncOk;
            const inactiveSlot = gitInactive.blueGreen?.inactiveSlot ?? "green";
            const slotCandidates = blueGreenDeploymentNameCandidates(projectName, inactiveSlot);
            sections.push(`[blue-green] waiting for inactive slot (${slotCandidates.join(" | ")}) in ${destNamespace}…`);
            const slotReady = await waitForAnyDeploymentReady(destNamespace, slotCandidates, env.PAAS_BLUE_GREEN_WAIT_DEPLOY_MS);
            sections.push(`[blue-green] ${slotReady.message}`);
            if (!slotReady.ready) {
                sections.push(`PAAS_DEPLOY_VERIFY step=blue_green_inactive status=WARN detail=${slotReady.message.slice(0, 400)}`);
                sections.push("[blue-green] inactive slot failed — falling back to Rolling deploy");
                const rolling = await runRollingGitOpsPromote(
                    sections,
                    projectName,
                    destNamespace,
                    artifactRef,
                    gitopsOptions,
                    deployProfile.containerPort,
                    "(fallback after BlueGreen failure)"
                );
                argoSyncOk = rolling.argoSyncOk;
                workloadReady = rolling.workloadReady;
                if (rolling.shouldAbort) {
                    await persistFailure(deploymentId, projectId, sections.join("\n"), DeploymentFailureReason.ARGOCD, `Workload not ready after Rolling fallback: ${slotReady.message}`);
                    return;
                }
            }
            else {
                sections.push("PAAS_DEPLOY_VERIFY step=blue_green_inactive status=OK");
                workloadReady = true;
                sections.push("[deploy] strategy=BlueGreen phase=flip");
                const gitFlip = await commitHelmValuesGitHub(projectName, artifactRef, {
                    ...gitopsOptions,
                    blueGreenPhase: "flip"
                });
                sections.push(`[gitops] traffic switch committed ${gitFlip.ref} active=${gitFlip.blueGreen?.activeSlot ?? "?"}`);
                sections.push(`PAAS_DEPLOY_VERIFY step=gitops_flip status=OK detail=${gitFlip.ref}`);
                sections.push(`[build-meta] paas_strict_integrations=${env.PAAS_STRICT_INTEGRATIONS}`);
                const argoFlip = await appendArgoSyncAndWait(sections, projectName, destNamespace);
                if (argoFlip.shouldAbort) {
                    await persistFailure(deploymentId, projectId, sections.join("\n"), DeploymentFailureReason.ARGOCD, "Argo CD sync failed during blue-green traffic switch.");
                    return;
                }
                argoSyncOk = argoFlip.argoSyncOk;
            }
        }
        else {
            const rolling = await runRollingGitOpsPromote(
                sections,
                projectName,
                destNamespace,
                artifactRef,
                gitopsOptions,
                deployProfile.containerPort,
                ""
            );
            if (rolling.shouldAbort) {
                await persistFailure(deploymentId, projectId, sections.join("\n"), DeploymentFailureReason.ARGOCD, "Argo CD application did not become Healthy and Synced in time.");
                return;
            }
            argoSyncOk = rolling.argoSyncOk;
            workloadReady = rolling.workloadReady;
        }
    }
    catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        sections.push(`[gitops] FAILED: ${msg}`);
        sections.push(`PAAS_DEPLOY_VERIFY step=gitops status=FAIL detail=${msg.slice(0, 400)}`);
        await persistFailure(deploymentId, projectId, sections.join("\n"), DeploymentFailureReason.GITOPS, msg);
        return;
    }
    const appUrl = buildAppPublicUrl(projectName);
    const labIp = env.APPS_PUBLIC_LAB_NODE_IP.trim();
    let urlReachable = false;
    let reachabilityError: string | undefined;
    const postArgoDelayMs = Math.max(0, Number(process.env.PAAS_DEPLOY_POST_ARGO_PROBE_DELAY_MS ?? "15000") || 0);
    if (postArgoDelayMs > 0 && (argoSyncOk || env.PAAS_STRICT_INTEGRATIONS !== "true")) {
        sections.push(`[deploy] Waiting ${postArgoDelayMs}ms after Argo CD before HTTP probe…`);
        await new Promise((r) => setTimeout(r, postArgoDelayMs));
    }
    if (!labIp && !env.APPS_PUBLIC_URL_TEMPLATE.trim()) {
        sections.push(`PAAS_DEPLOY_VERIFY step=url status=WARN detail=${appUrl} — set APPS_PUBLIC_LAB_NODE_IP and APPS_PUBLIC_INGRESS_HTTP_PORT in PaaS env`);
    }
    else {
        const maxAttempts = Math.max(1, Math.floor(env.PAAS_DEPLOY_WAIT_HTTP_MS / env.PAAS_DEPLOY_HTTP_POLL_MS));
        const reachability = await probeAppUrlReachability(appUrl, {
            maxAttempts,
            delayMs: env.PAAS_DEPLOY_HTTP_POLL_MS,
            namespace: destNamespace,
            projectName
        });
        urlReachable = reachability.reachable;
        reachabilityError = reachability.error;
        if (reachability.reachable) {
            const viaNote = reachability.via === "in_cluster"
                ? " (verified via in-cluster Service; public ingress may still propagate)"
                : "";
            sections.push(`PAAS_DEPLOY_VERIFY step=url status=OK detail=${appUrl} HTTP ${reachability.statusCode ?? "?"}${viaNote}`);
        }
        else {
            sections.push(`PAAS_DEPLOY_VERIFY step=url status=FAIL detail=${appUrl} (${reachability.error ?? "unreachable"})`);
        }
    }
    const probeConfigured = Boolean(labIp || env.APPS_PUBLIC_URL_TEMPLATE.trim());
    if (probeConfigured && !urlReachable && !workloadReady) {
        const msg = `Pods not ready and URL not reachable (${appUrl}). Cluster auto-heal was applied; retry Deploy from PaaS or fix the application build.`;
        sections.push(`[deploy] FAILED: ${msg}`);
        await persistFailure(deploymentId, projectId, sections.join("\n"), DeploymentFailureReason.ARGOCD, msg);
        return;
    }
    else if (probeConfigured && !urlReachable && workloadReady) {
        if (reachabilityError === "client_side_exception" || reachabilityError === "angular_template_error") {
            const msg = `Application returned HTTP 200 but has client-side errors (${reachabilityError}). Fix app source or set NEXT_PUBLIC_* in Edit project → Application environment, then Deploy again.`;
            sections.push(`[deploy] FAILED: ${msg}`);
            await persistFailure(deploymentId, projectId, sections.join("\n"), DeploymentFailureReason.UNKNOWN, msg);
            return;
        }
        sections.push(`PAAS_DEPLOY_VERIFY step=url status=WARN detail=${appUrl} unreachable but workload ready — marking DEPLOYED`);
    }
    const okLog = tail(sections.join("\n"));
    await prisma.deployment.update({
        where: { id: deploymentId },
        data: {
            status: DeploymentJobStatus.DEPLOYED,
            logs: okLog,
            url: appUrl,
            ...clearDeploymentFailureFields()
        }
    });
    await updateProject(projectId, {
        lastDeploymentStatus: "DEPLOYED",
        buildStatus: "READY",
        deploymentLogs: okLog,
        imageTag: artifactRef,
        url: appUrl
    });
}
