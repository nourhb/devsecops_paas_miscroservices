type BuildSuggestionInput = {
    description?: string;
    currentValues?: {
        projectName?: string;
        buildType?: string;
        deliveryType?: string;
    };
};
type BuildAnalysisInput = {
    status?: string;
    projectName?: string;
    buildType?: string;
    deliveryType?: string;
    errorMessage?: string;
    description?: string;
    logs?: string;
};
type SuggestionResult = {
    projectName: string;
    buildType: string;
    deliveryType: string;
    buildTool: string;
    pipelineSteps: string[];
    jenkinsParameters: {
        projectName: string;
        buildType: string;
        deliveryType: string;
    };
    reasoning: string;
    source: "openai" | "mock";
};
type AnalysisResult = {
    message: string;
    nextStep: string;
    stage: string;
    source: "openai" | "mock";
};
const OPENAI_API_URL = "https://api.openai.com/v1/chat/completions";
const OPENAI_MODEL = (process.env.OPENAI_MODEL || "gpt-4o-mini").trim();
const OPENAI_TIMEOUT_MS = 15000;
function normalizeText(value?: string | null) {
    return String(value || "").trim();
}
function slugify(value: string) {
    return value
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/^-+|-+$/g, "")
        .replace(/-{2,}/g, "-");
}
function deriveProjectName(description: string, fallbackName?: string) {
    const normalizedFallback = normalizeText(fallbackName);
    if (normalizedFallback) {
        return slugify(normalizedFallback);
    }
    const cleaned = description
        .toLowerCase()
        .replace(/[^a-z0-9\s-]/g, " ")
        .split(/\s+/)
        .filter((token) => token && token.length > 2)
        .slice(0, 3)
        .join("-");
    return slugify(cleaned || "devops-app");
}
function deriveBuildType(description: string, fallbackBuildType?: string) {
    const normalizedFallback = normalizeText(fallbackBuildType);
    if (normalizedFallback) {
        return normalizedFallback;
    }
    const lowerDescription = description.toLowerCase();
    if (/(hotfix|urgent|patch)/.test(lowerDescription)) {
        return "hotfix";
    }
    if (/(prod|production|release|deploy)/.test(lowerDescription)) {
        return "release";
    }
    if (/(test|qa|preview|staging)/.test(lowerDescription)) {
        return "staging";
    }
    return "snapshot";
}
function deriveDeliveryType(description: string, fallbackDeliveryType?: string) {
    const normalizedFallback = normalizeText(fallbackDeliveryType);
    if (normalizedFallback) {
        return normalizedFallback;
    }
    const lowerDescription = description.toLowerCase();
    if (/canary/.test(lowerDescription)) {
        return "canary";
    }
    if (/(prod|production|public|customer)/.test(lowerDescription)) {
        return "external";
    }
    if (/(team|internal|platform|devops)/.test(lowerDescription)) {
        return "internal";
    }
    return "internal";
}
function deriveBuildTool(description: string) {
    const lowerDescription = description.toLowerCase();
    if (/(spring|java|maven|boot)/.test(lowerDescription)) {
        return "Maven";
    }
    if (/(node|next|react|frontend|npm)/.test(lowerDescription)) {
        return "npm";
    }
    if (/(python|fastapi|django)/.test(lowerDescription)) {
        return "pip";
    }
    return "Maven";
}
function derivePipelineSteps(description: string) {
    const lowerDescription = description.toLowerCase();
    const buildTool = deriveBuildTool(description);
    const steps = [
        `Build (${buildTool})`,
        "Test",
        "SonarQube Scan",
        "Dependency Track",
        "Docker Image",
        "ArgoCD Deploy",
    ];
    if (/(security|compliance|signed)/.test(lowerDescription)) {
        steps.splice(4, 0, "Policy Gate");
    }
    return steps;
}
function buildSuggestionFallback(input: BuildSuggestionInput): SuggestionResult {
    const description = normalizeText(input.description);
    const currentValues = input.currentValues || {};
    const projectName = deriveProjectName(description, currentValues.projectName);
    const buildType = deriveBuildType(description, currentValues.buildType);
    const deliveryType = deriveDeliveryType(description, currentValues.deliveryType);
    const buildTool = deriveBuildTool(description);
    const pipelineSteps = derivePipelineSteps(description);
    return {
        projectName,
        buildType,
        deliveryType,
        buildTool,
        pipelineSteps,
        jenkinsParameters: {
            projectName,
            buildType,
            deliveryType,
        },
        reasoning: description
            ? "Suggested from the project description using lightweight DevOps rules."
            : "Suggested from the current form values because no project description was provided.",
        source: "mock",
    };
}
function buildAnalysisFallback(input: BuildAnalysisInput): AnalysisResult {
    const status = normalizeText(input.status).toUpperCase();
    const errorMessage = normalizeText(input.errorMessage).toLowerCase();
    const logs = normalizeText(input.logs).toLowerCase();
    const combinedText = `${errorMessage}\n${logs}`;
    if (status === "SUCCESS") {
        return {
            message: "Build successful, ready for deployment.",
            nextStep: "Promote through ArgoCD and monitor application health.",
            stage: "Deploy (ArgoCD)",
            source: "mock",
        };
    }
    if (/non-resolvable parent pom|could not resolve dependenc|failed to collect dependenc|version conflict|pom\.xml|artifact not found/.test(combinedText)) {
        return {
            message: "Build failed because Maven dependencies could not be resolved cleanly.",
            nextStep: "Check pom.xml version conflicts, repository access, and dependency coordinates.",
            stage: "Build",
            source: "mock",
        };
    }
    if (/test(s)? run:|tests run:|jest|vitest|playwright|surefire|failing test|assertionerror/.test(combinedText)) {
        return {
            message: "Build failed because one or more tests likely did not pass.",
            nextStep: "Inspect the failing test stage and rerun after fixing the broken checks.",
            stage: "Test",
            source: "mock",
        };
    }
    if (/quality gate|sonarqube|sonar-scanner|sonar scanner/.test(combinedText)) {
        return {
            message: "Build stopped during SonarQube analysis or quality-gate validation.",
            nextStep: "Review the SonarQube report and fix blocking issues before retrying.",
            stage: "SonarQube",
            source: "mock",
        };
    }
    if (/dependency-check|owasp|cvss|vulnerab|suppression\.xml/.test(combinedText)) {
        return {
            message: "Build failed during dependency scanning because a vulnerable package was flagged.",
            nextStep: "Review the dependency report and upgrade or suppress the affected package intentionally.",
            stage: "Dependency Check",
            source: "mock",
        };
    }
    if (/docker build|docker push|buildx|no basic auth credentials|denied: requested access|manifest unknown/.test(combinedText)) {
        return {
            message: "Build failed while building or pushing the Docker image.",
            nextStep: "Check image tags, registry credentials, and Dockerfile build arguments.",
            stage: "Docker",
            source: "mock",
        };
    }
    if (/argocd|argo cd|sync failed|rollout status|imagepullbackoff|crashloopbackoff|kubectl apply/.test(combinedText)) {
        return {
            message: "Build completed but deployment failed during the ArgoCD rollout.",
            nextStep: "Inspect ArgoCD sync status, Kubernetes events, and container startup errors.",
            stage: "Deploy (ArgoCD)",
            source: "mock",
        };
    }
    if (/timeout|timed out|network|connect|connection refused|econnreset/.test(combinedText)) {
        return {
            message: "Build failed due to a possible network or infrastructure timeout.",
            nextStep: "Check Jenkins agent health, registry connectivity, and external service access.",
            stage: "Build",
            source: "mock",
        };
    }
    return {
        message: "Build failed. Check Jenkins logs for dependency, configuration, or infrastructure issues.",
        nextStep: "Start with the failing Jenkins stage, then review SonarQube and Dependency Track outputs.",
        stage: "Build",
        source: "mock",
    };
}
function trimLogsForAnalysis(logs?: string) {
    const normalizedLogs = normalizeText(logs);
    if (!normalizedLogs) {
        return "";
    }
    return normalizedLogs.length > 5000
        ? normalizedLogs.slice(-5000)
        : normalizedLogs;
}
function parseJsonContent(content: string) {
    try {
        return JSON.parse(content);
    }
    catch {
        return null;
    }
}
async function requestOpenAiJson(systemPrompt: string, userPrompt: string) {
    const apiKey = normalizeText(process.env.OPENAI_API_KEY);
    if (!apiKey) {
        return null;
    }
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), OPENAI_TIMEOUT_MS);
    try {
        const response = await fetch(OPENAI_API_URL, {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                Authorization: `Bearer ${apiKey}`,
            },
            body: JSON.stringify({
                model: OPENAI_MODEL,
                temperature: 0.2,
                response_format: { type: "json_object" },
                messages: [
                    {
                        role: "system",
                        content: systemPrompt,
                    },
                    {
                        role: "user",
                        content: userPrompt,
                    },
                ],
            }),
            signal: controller.signal,
            cache: "no-store",
        });
        if (!response.ok) {
            return null;
        }
        const payload = (await response.json()) as {
            choices?: Array<{
                message?: {
                    content?: string;
                };
            }>;
        };
        const content = payload.choices?.[0]?.message?.content;
        if (!content) {
            return null;
        }
        return parseJsonContent(content);
    }
    catch {
        return null;
    }
    finally {
        clearTimeout(timeoutId);
    }
}
export async function suggestBuildParametersWithAi(input: BuildSuggestionInput): Promise<SuggestionResult> {
    const fallback = buildSuggestionFallback(input);
    const description = normalizeText(input.description);
    const currentValues = input.currentValues || {};
    const aiResponse = await requestOpenAiJson("You are a DevOps build assistant. Respond only as JSON with projectName, buildType, deliveryType, buildTool, pipelineSteps, and reasoning. Keep values concise, production-safe, and practical.", JSON.stringify({
        description,
        currentValues,
        allowedBuildTypes: ["snapshot", "staging", "release", "hotfix"],
        allowedDeliveryTypes: ["internal", "external", "canary"],
        allowedBuildTools: ["Maven", "npm", "pip"],
    }));
    if (!aiResponse || typeof aiResponse !== "object") {
        return fallback;
    }
    const projectName = deriveProjectName(normalizeText((aiResponse as {
        projectName?: string;
    }).projectName) || description, currentValues.projectName);
    const buildType = deriveBuildType(normalizeText((aiResponse as {
        buildType?: string;
    }).buildType) || description, currentValues.buildType);
    const deliveryType = deriveDeliveryType(normalizeText((aiResponse as {
        deliveryType?: string;
    }).deliveryType) || description, currentValues.deliveryType);
    const reasoning = normalizeText((aiResponse as {
        reasoning?: string;
    }).reasoning) ||
        fallback.reasoning;
    const buildTool = normalizeText((aiResponse as {
        buildTool?: string;
    }).buildTool) ||
        fallback.buildTool;
    const rawSteps: unknown[] = Array.isArray((aiResponse as {
        pipelineSteps?: unknown[];
    }).pipelineSteps)
        ? (aiResponse as {
            pipelineSteps?: unknown[];
        }).pipelineSteps || []
        : [];
    const pipelineSteps = rawSteps
        .map((step) => normalizeText(String(step)))
        .filter(Boolean)
        .slice(0, 8);
    return {
        projectName,
        buildType,
        deliveryType,
        buildTool,
        pipelineSteps: pipelineSteps.length ? pipelineSteps : fallback.pipelineSteps,
        jenkinsParameters: {
            projectName,
            buildType,
            deliveryType,
        },
        reasoning,
        source: "openai",
    };
}
export async function analyzeBuildResultWithAi(input: BuildAnalysisInput): Promise<AnalysisResult> {
    const fallback = buildAnalysisFallback(input);
    const logs = trimLogsForAnalysis(input.logs);
    const aiResponse = await requestOpenAiJson("You are a DevOps pipeline analyzer. Respond only as JSON with message, nextStep, and stage. Keep all values short, practical, and non-alarmist. The stage must be one of: Build, Test, SonarQube, Dependency Check, Docker, Deploy (ArgoCD).", JSON.stringify({
        status: normalizeText(input.status),
        projectName: normalizeText(input.projectName),
        buildType: normalizeText(input.buildType),
        deliveryType: normalizeText(input.deliveryType),
        description: normalizeText(input.description),
        errorMessage: normalizeText(input.errorMessage),
        logs,
    }));
    if (!aiResponse || typeof aiResponse !== "object") {
        return fallback;
    }
    const message = normalizeText((aiResponse as {
        message?: string;
    }).message);
    const nextStep = normalizeText((aiResponse as {
        nextStep?: string;
    }).nextStep);
    const stage = normalizeText((aiResponse as {
        stage?: string;
    }).stage);
    return {
        message: message || fallback.message,
        nextStep: nextStep || fallback.nextStep,
        stage: stage || fallback.stage,
        source: "openai",
    };
}
