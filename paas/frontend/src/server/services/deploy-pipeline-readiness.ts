import { env } from "@/server/config/env";
import { isRealConfigured, realValueOrEmpty } from "@/server/config/real-values";
import { getCustomObjectsApi, isKubernetesConfigured } from "@/server/integrations/kubernetes-client";
import { allowSimulation } from "@/server/integrations/integration-mode";
export interface DeployPipelineReadiness {
    simulationEnabled: boolean;
    buildBackend: {
        selected: "jenkins" | "tekton";
        configured: boolean;
    };
    jenkins: {
        configured: boolean;
    };
    tekton: {
        configured: boolean;
        namespace: string;
        pipeline: string;
    };
    gitops: {
        configured: boolean;
    };
    argocd: {
        configured: boolean;
    };
    appsPublicUrl: {
        configured: boolean;
    };
    missingForFullPipeline: string[];
}
export function getDeployPipelineReadiness(): DeployPipelineReadiness {
    const jenkinsConfigured = isRealConfigured(env.JENKINS_BASE_URL, env.JENKINS_USERNAME, env.JENKINS_API_TOKEN);
    const tektonConfigured = Boolean(isKubernetesConfigured() && getCustomObjectsApi() && env.TEKTON_NAMESPACE.trim());
    const gitopsConfigured = isRealConfigured(env.GITOPS_REPO_URL, env.GITOPS_REPO_TOKEN);
    const argocdAuthConfigured = Boolean(realValueOrEmpty(env.ARGOCD_AUTH_TOKEN) || realValueOrEmpty(env.ARGOCD_PASSWORD));
    const argocdConfigured = isRealConfigured(env.ARGOCD_BASE_URL) && argocdAuthConfigured;
    const appsConfigured = Boolean(realValueOrEmpty(env.APPS_PUBLIC_URL_TEMPLATE) ||
        (realValueOrEmpty(env.APPS_PUBLIC_BASE_DOMAIN) && realValueOrEmpty(env.APPS_PUBLIC_URL_SCHEME)));
    const simulationEnabled = allowSimulation();
    const missingForFullPipeline: string[] = [];
    if (env.BUILD_BACKEND === "jenkins" && !jenkinsConfigured) {
        missingForFullPipeline.push("JENKINS_URL (or JENKINS_BASE_URL), JENKINS_USERNAME (or JENKINS_USER), JENKINS_API_TOKEN (or JENKINS_TOKEN)");
    }
    if (env.BUILD_BACKEND === "tekton" && !tektonConfigured) {
        missingForFullPipeline.push("Kubernetes cluster access with Tekton installed in TEKTON_NAMESPACE");
    }
    if (!gitopsConfigured) {
        missingForFullPipeline.push("GITOPS_REPO_URL, GITOPS_REPO_TOKEN");
    }
    if (!argocdConfigured) {
        missingForFullPipeline.push("ARGOCD_BASE_URL (or ARGOCD_URL), ARGOCD_AUTH_TOKEN (or ARGOCD_TOKEN) or ARGOCD_PASSWORD");
    }
    if (!appsConfigured) {
        missingForFullPipeline.push("APPS_PUBLIC_BASE_DOMAIN (+ APPS_PUBLIC_URL_SCHEME) or APPS_PUBLIC_URL_TEMPLATE");
    }
    if (simulationEnabled) {
        return {
            simulationEnabled: true,
            buildBackend: { selected: env.BUILD_BACKEND, configured: env.BUILD_BACKEND === "tekton" ? tektonConfigured : jenkinsConfigured },
            jenkins: { configured: jenkinsConfigured },
            tekton: {
                configured: tektonConfigured,
                namespace: env.TEKTON_NAMESPACE,
                pipeline: env.TEKTON_NODE_PIPELINE_NAME
            },
            gitops: { configured: gitopsConfigured },
            argocd: { configured: argocdConfigured },
            appsPublicUrl: { configured: appsConfigured },
            missingForFullPipeline: []
        };
    }
    return {
        simulationEnabled: false,
        buildBackend: { selected: env.BUILD_BACKEND, configured: env.BUILD_BACKEND === "tekton" ? tektonConfigured : jenkinsConfigured },
        jenkins: { configured: jenkinsConfigured },
        tekton: {
            configured: tektonConfigured,
            namespace: env.TEKTON_NAMESPACE,
            pipeline: env.TEKTON_NODE_PIPELINE_NAME
        },
        gitops: { configured: gitopsConfigured },
        argocd: { configured: argocdConfigured },
        appsPublicUrl: { configured: appsConfigured },
        missingForFullPipeline
    };
}
