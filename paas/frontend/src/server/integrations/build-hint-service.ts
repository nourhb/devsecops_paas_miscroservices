/**

 * Guess Jenkins-ish fields from a repo blurb + summarize ugly console tails.

 * With no API key we stay fully offline (regex heuristics in this module).

 */

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

export type BuildHintSuggestion = {

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

    /** `remote` = looked up via provider API; `local` = rules in this file */

    source: "remote" | "local";

};

export type BuildHintAnalysis = {

    message: string;

    nextStep: string;

    stage: string;

    source: "remote" | "local";

};



const CHAT_COMPLETIONS_URL = "https://api.openai.com/v1/chat/completions";

const OPENAI_MODEL = (process.env.OPENAI_MODEL || "gpt-4o-mini").trim();

const REMOTE_TIMEOUT_MS = 15000;



const JSON_SUGGEST_SYSTEM = [

    "Reply with a single JSON object only.",

    "Keys: projectName, buildType, deliveryType, buildTool, pipelineSteps (string array), reasoning (one short sentence).",

    "buildType in snapshot | staging | release | hotfix; deliveryType in internal | external | canary; buildTool in Maven | npm | pip.",

    "Keep strings short and boring—nothing marketing.",

].join(" ");



const JSON_ANALYZE_SYSTEM = [

    "Reply with a single JSON object only.",

    "Keys: message, nextStep, stage.",

    "stage must be exactly one of: Build, Test, SonarQube, Dependency Check, Docker, Deploy (ArgoCD).",

    "Short lines, no panic tone.",

].join(" ");



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

    const steps = [`Build (${buildTool})`, "Test", "SonarQube Scan", "Dependency Track", "Docker Image", "ArgoCD Deploy"];

    if (/(security|compliance|signed)/.test(lowerDescription)) {

        steps.splice(4, 0, "Policy Gate");

    }

    return steps;

}

function buildSuggestionFallback(input: BuildSuggestionInput): BuildHintSuggestion {

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

        jenkinsParameters: { projectName, buildType, deliveryType },

        reasoning: description

            ? "From a few regex rules on what you typed in the repo box."

            : "No repo blurb yet — reused the fields you already picked.",

        source: "local",

    };

}

function buildAnalysisFallback(input: BuildAnalysisInput): BuildHintAnalysis {

    const status = normalizeText(input.status).toUpperCase();

    const errorMessage = normalizeText(input.errorMessage).toLowerCase();

    const logs = normalizeText(input.logs).toLowerCase();

    const combinedText = `${errorMessage}\n${logs}`;

    if (status === "SUCCESS") {

        return {

            message: "Build went green.",

            nextStep: "Bump the image tag in GitOps and watch Argo CD sync.",

            stage: "Deploy (ArgoCD)",

            source: "local",

        };

    }

    if (/non-resolvable parent pom|could not resolve dependenc|failed to collect dependenc|version conflict|pom\.xml|artifact not found/.test(combinedText)) {

        return {

            message: "Maven blew up resolving dependencies.",

            nextStep: "Open pom versions and fix repo access.",

            stage: "Build",

            source: "local",

        };

    }

    if (/test(s)? run:|tests run:|jest|vitest|playwright|surefire|failing test|assertionerror/.test(combinedText)) {

        return {

            message: "Tests didn't pass somewhere in the pipeline.",

            nextStep: "Scroll to the failing test block in the Jenkins log.",

            stage: "Test",

            source: "local",

        };

    }

    if (/quality gate|sonarqube|sonar-scanner|sonar scanner/.test(combinedText)) {

        return {

            message: "Sonar gate blocked the job.",

            nextStep: "Fix the hotspots Sonar flagged, rerun.",

            stage: "SonarQube",

            source: "local",

        };

    }

    if (/dependency-check|owasp|cvss|vulnerab|suppression\.xml/.test(combinedText)) {

        return {

            message: "Dependency scan yelled about a vuln.",

            nextStep: "Upgrade the lib or consciously suppress with audit trail.",

            stage: "Dependency Check",

            source: "local",

        };

    }

    if (/docker build|docker push|buildx|no basic auth credentials|denied: requested access|manifest unknown/.test(combinedText)) {

        return {

            message: "Docker build or push bombed.",

            nextStep: "Check registry login, tag spelling, Dockerfile COPY paths.",

            stage: "Docker",

            source: "local",

        };

    }

    if (/argocd|argo cd|sync failed|rollout status|imagepullbackoff|crashloopbackoff|kubectl apply/.test(combinedText)) {

        return {

            message: "Cluster side failed after the image was pushed.",

            nextStep: "Argo UI + kubectl describe pod is your friend.",

            stage: "Deploy (ArgoCD)",

            source: "local",

        };

    }

    if (/timeout|timed out|network|connect|connection refused|econnreset/.test(combinedText)) {

        return {

            message: "Smells like infra/network flake.",

            nextStep: "Ping the agent / registry / VPN.",

            stage: "Build",

            source: "local",

        };

    }

    return {

        message: "Red build — reason isn't obvious from keywords alone.",

        nextStep: "Read Jenkins console tab by tab; security scans come second.",

        stage: "Build",

        source: "local",

    };

}

function trimLogsForAnalysis(logs?: string) {

    const normalizedLogs = normalizeText(logs);

    if (!normalizedLogs) {

        return "";

    }

    return normalizedLogs.length > 5000 ? normalizedLogs.slice(-5000) : normalizedLogs;

}

function parseJsonContent(content: string) {

    try {

        return JSON.parse(content);

    }

    catch {

        return null;

    }

}



async function requestRemoteJson(systemPrompt: string, userPrompt: string) {

    const apiKey = normalizeText(process.env.OPENAI_API_KEY);

    if (!apiKey) {

        return null;

    }

    const controller = new AbortController();

    const timeoutId = setTimeout(() => controller.abort(), REMOTE_TIMEOUT_MS);

    try {

        const response = await fetch(CHAT_COMPLETIONS_URL, {

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

                    { role: "system", content: systemPrompt },

                    { role: "user", content: userPrompt },

                ],

            }),

            signal: controller.signal,

            cache: "no-store",

        });

        if (!response.ok) {

            return null;

        }

        const payload = (await response.json()) as {

            choices?: Array<{ message?: { content?: string } }>;

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



export async function suggestBuildParameters(input: BuildSuggestionInput): Promise<BuildHintSuggestion> {

    const fallback = buildSuggestionFallback(input);

    const description = normalizeText(input.description);

    const currentValues = input.currentValues || {};

    const parsed = await requestRemoteJson(JSON_SUGGEST_SYSTEM, JSON.stringify({

        description,

        currentValues,

        allowedBuildTypes: ["snapshot", "staging", "release", "hotfix"],

        allowedDeliveryTypes: ["internal", "external", "canary"],

        allowedBuildTools: ["Maven", "npm", "pip"],

    }));

    if (!parsed || typeof parsed !== "object") {

        return fallback;

    }

    const projectName = deriveProjectName(

        normalizeText((parsed as { projectName?: string }).projectName) || description,

        currentValues.projectName,

    );

    const buildType = deriveBuildType(normalizeText((parsed as { buildType?: string }).buildType) || description, currentValues.buildType);

    const deliveryType = deriveDeliveryType(

        normalizeText((parsed as { deliveryType?: string }).deliveryType) || description,

        currentValues.deliveryType,

    );

    const reasoning =

        normalizeText((parsed as { reasoning?: string }).reasoning) || fallback.reasoning;

    const buildTool = normalizeText((parsed as { buildTool?: string }).buildTool) || fallback.buildTool;

    const rawSteps: unknown[] = Array.isArray((parsed as { pipelineSteps?: unknown[] }).pipelineSteps)

        ? ((parsed as { pipelineSteps?: unknown[] }).pipelineSteps || [])

        : [];

    const pipelineSteps = rawSteps.map((step) => normalizeText(String(step))).filter(Boolean).slice(0, 8);

    return {

        projectName,

        buildType,

        deliveryType,

        buildTool,

        pipelineSteps: pipelineSteps.length ? pipelineSteps : fallback.pipelineSteps,

        jenkinsParameters: { projectName, buildType, deliveryType },

        reasoning,

        source: "remote",

    };

}



export async function summarizeBuildOutcome(input: BuildAnalysisInput): Promise<BuildHintAnalysis> {

    const fallback = buildAnalysisFallback(input);

    const logs = trimLogsForAnalysis(input.logs);

    const parsed = await requestRemoteJson(JSON_ANALYZE_SYSTEM, JSON.stringify({

        status: normalizeText(input.status),

        projectName: normalizeText(input.projectName),

        buildType: normalizeText(input.buildType),

        deliveryType: normalizeText(input.deliveryType),

        description: normalizeText(input.description),

        errorMessage: normalizeText(input.errorMessage),

        logs,

    }));

    if (!parsed || typeof parsed !== "object") {

        return fallback;

    }

    const message = normalizeText((parsed as { message?: string }).message);

    const nextStep = normalizeText((parsed as { nextStep?: string }).nextStep);

    const stage = normalizeText((parsed as { stage?: string }).stage);

    return {

        message: message || fallback.message,

        nextStep: nextStep || fallback.nextStep,

        stage: stage || fallback.stage,

        source: "remote",

    };

}
