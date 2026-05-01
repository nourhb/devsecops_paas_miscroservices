"use client";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Activity, Bot, CircleCheckBig, Clock3, Server, XCircle } from "lucide-react";
import { toast } from "sonner";
import BuildForm from "@/components/jenkins/BuildForm";
import BuildLogs from "@/components/jenkins/BuildLogs";
import PipelineTimeline from "@/components/jenkins/PipelineTimeline";
import BuildTable from "@/components/jenkins/BuildTable";
import { jenkinsUi } from "@/lib/api";
const STORAGE_KEY = "jenkins-build-history";
const POLL_INTERVAL_MS = 3000;
const TERMINAL_STATUSES = new Set(["SUCCESS", "FAILED"]);
const ACTIVE_STATUSES = new Set(["QUEUED", "RUNNING"]);
const API_TARGET = (process.env.NEXT_PUBLIC_API_BASE_URL || process.env.NEXT_PUBLIC_API_URL || "")
    .trim()
    .replace(/\/+$/, "") || "same-origin";
const DEFAULT_FORM_VALUES = {
    projectDescription: "",
    projectGroupName: "",
    projectName: "",
    projectTag: "",
    buildType: "",
    email: "",
    deliveryType: "",
};
function createBuildId() {
    return `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
}
function formatClockTime(timestamp) {
    if (!timestamp) {
        return "-";
    }
    return new Date(timestamp).toLocaleTimeString([], {
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
    });
}
function createStatusHistory(status, timestamp) {
    return {
        [status]: timestamp,
    };
}
function resolveJobName(formValues) {
    return (process.env.NEXT_PUBLIC_JENKINS_JOB_NAME || "").trim() || formValues.projectName;
}
function toBuildParams(formValues) {
    return {
        projectGroupName: formValues.projectGroupName,
        projectName: formValues.projectName,
        projectTag: formValues.projectTag,
        buildType: formValues.buildType,
        email: formValues.email,
        deliveryType: formValues.deliveryType,
    };
}
function buildAnalysisFallback(status, projectName) {
    if (status === "SUCCESS") {
        return `Build successful for ${projectName}, ready for deployment.`;
    }
    return `Build failed for ${projectName}. Check Jenkins logs for the root cause.`;
}
function createLogEntry(type, title, message, status) {
    return {
        id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
        type,
        title,
        message,
        status: status || "",
        timestamp: new Date().toISOString(),
    };
}
function readStatusCandidate(payload) {
    if (!payload) {
        return "";
    }
    if (typeof payload === "string") {
        return payload;
    }
    return (payload.status ||
        payload.buildStatus ||
        payload.result ||
        payload.state ||
        payload.data?.status ||
        payload.data?.result ||
        payload.jobStatus ||
        "");
}
function normalizeStatus(payload) {
    const rawStatus = String(readStatusCandidate(payload)).trim().toUpperCase();
    if (!rawStatus) {
        return "QUEUED";
    }
    if (["QUEUED", "PENDING", "WAITING", "CREATED"].includes(rawStatus)) {
        return "QUEUED";
    }
    if (["RUNNING", "BUILDING", "IN_PROGRESS", "STARTED"].includes(rawStatus)) {
        return "RUNNING";
    }
    if (["SUCCESS", "SUCCEEDED", "COMPLETED"].includes(rawStatus)) {
        return "SUCCESS";
    }
    if (["FAILED", "FAILURE", "ERROR", "ABORTED", "CANCELLED"].includes(rawStatus)) {
        return "FAILED";
    }
    return "QUEUED";
}
function normalizeStoredBuild(build) {
    if (!build || typeof build !== "object") {
        return null;
    }
    const normalizedStatus = build.status === "WAITING" ? "QUEUED" : build.status || "QUEUED";
    return {
        ...build,
        status: normalizedStatus,
        analysis: build.analysis || "",
        analysisSource: build.analysisSource || "",
        analysisNextStep: build.analysisNextStep || "",
        analysisStage: build.analysisStage || "",
        statusHistory: build.statusHistory && typeof build.statusHistory === "object"
            ? build.statusHistory
            : createStatusHistory(normalizedStatus, build.lastCheckedAt || build.submittedAt || new Date().toISOString()),
    };
}
function getActiveBuilds(builds) {
    return builds.filter((build) => ACTIVE_STATUSES.has(build.status));
}
function readStoredBuilds() {
    if (typeof window === "undefined") {
        return [];
    }
    try {
        const storedValue = window.localStorage.getItem(STORAGE_KEY);
        if (!storedValue) {
            return [];
        }
        const parsedValue = JSON.parse(storedValue);
        return Array.isArray(parsedValue)
            ? parsedValue.map(normalizeStoredBuild).filter(Boolean)
            : [];
    }
    catch {
        return [];
    }
}
export default function JenkinsBuildPage() {
    const [builds, setBuilds] = useState([]);
    const [selectedJobFilter, setSelectedJobFilter] = useState("all");
    const [selectedStatusFilter, setSelectedStatusFilter] = useState("all");
    const [selectedBuildId, setSelectedBuildId] = useState("");
    const [isSubmitting, setIsSubmitting] = useState(false);
    const [feedback, setFeedback] = useState(null);
    const [lastSubmittedValues, setLastSubmittedValues] = useState(DEFAULT_FORM_VALUES);
    const [aiSuggestion, setAiSuggestion] = useState(null);
    const [isSuggesting, setIsSuggesting] = useState(false);
    const [logs, setLogs] = useState([]);
    const [consoleLog, setConsoleLog] = useState(null);
    const [pollMeta, setPollMeta] = useState({
        isPolling: false,
        lastUpdatedAt: "",
        nextRefreshAt: "",
    });
    const [nowTimestamp, setNowTimestamp] = useState(Date.now());
    const hasRestoredBuilds = useRef(false);
    const isMountedRef = useRef(false);
    const buildsRef = useRef([]);
    const pollTimeoutRef = useRef(null);
    const pollAbortControllerRef = useRef(null);
    const isPollingRef = useRef(false);
    const pollStatusesRef = useRef(null);
    const analyzingBuildIdsRef = useRef(new Set());
    const addLog = useCallback((type, title, message, status) => {
        setLogs((currentLogs) => [
            createLogEntry(type, title, message, status),
            ...currentLogs,
        ].slice(0, 20));
    }, []);
    const availableJobs = useMemo(() => Array.from(new Set(builds.map((build) => build.jobName).filter(Boolean))).sort(), [builds]);
    const filteredBuilds = useMemo(() => builds.filter((build) => {
        if (selectedJobFilter !== "all" && build.jobName !== selectedJobFilter) {
            return false;
        }
        if (selectedStatusFilter !== "all" && build.status !== selectedStatusFilter) {
            return false;
        }
        return true;
    }), [builds, selectedJobFilter, selectedStatusFilter]);
    const primaryBuild = useMemo(() => {
        const selected = filteredBuilds.find((build) => build.id === selectedBuildId) ||
            builds.find((build) => build.id === selectedBuildId);
        return selected || filteredBuilds.find((build) => build.buildNumber) || filteredBuilds[0] || null;
    }, [builds, filteredBuilds, selectedBuildId]);
    const clearPollTimeout = useCallback(() => {
        if (pollTimeoutRef.current) {
            window.clearTimeout(pollTimeoutRef.current);
            pollTimeoutRef.current = null;
        }
    }, []);
    const stopPolling = useCallback(() => {
        clearPollTimeout();
        setPollMeta((currentMeta) => ({
            ...currentMeta,
            isPolling: false,
            nextRefreshAt: "",
        }));
        if (pollAbortControllerRef.current) {
            pollAbortControllerRef.current.abort();
            pollAbortControllerRef.current = null;
        }
    }, [clearPollTimeout]);
    const schedulePoll = useCallback((delay = POLL_INTERVAL_MS) => {
        clearPollTimeout();
        if (!isMountedRef.current || isPollingRef.current) {
            return;
        }
        if (!getActiveBuilds(buildsRef.current).length) {
            return;
        }
        setPollMeta((currentMeta) => ({
            ...currentMeta,
            nextRefreshAt: new Date(Date.now() + delay).toISOString(),
        }));
        pollTimeoutRef.current = window.setTimeout(() => {
            pollTimeoutRef.current = null;
            void pollStatusesRef.current?.();
        }, delay);
    }, [clearPollTimeout]);
    const pollStatuses = useCallback(async () => {
        const activeBuilds = getActiveBuilds(buildsRef.current);
        if (!activeBuilds.length || isPollingRef.current) {
            return;
        }
        isPollingRef.current = true;
        setPollMeta((currentMeta) => ({
            ...currentMeta,
            isPolling: true,
        }));
        if (pollAbortControllerRef.current) {
            pollAbortControllerRef.current.abort();
        }
        const abortController = new AbortController();
        pollAbortControllerRef.current = abortController;
        const polledAt = new Date().toISOString();
        const previousBuildsById = new Map(activeBuilds.map((build) => [build.id, build]));
        try {
            const updates = await Promise.all(Array.from(new Set(activeBuilds.map((build) => build.jobName))).map(async (jobName) => {
                try {
                    const response = await jenkinsUi.builds(jobName, abortController.signal);
                    return {
                        jobName,
                        builds: response.builds || [],
                        errorMessage: "",
                        aborted: false,
                    };
                }
                catch (error) {
                    if (error?.name === "AbortError") {
                        return {
                            jobName,
                            builds: [],
                            errorMessage: "",
                            aborted: true,
                        };
                    }
                    return {
                        jobName,
                        builds: [],
                        errorMessage: error.message || "Unable to fetch Jenkins builds.",
                        aborted: false,
                    };
                }
            }));
            if (!isMountedRef.current || abortController.signal.aborted) {
                return;
            }
            setPollMeta((currentMeta) => ({
                ...currentMeta,
                lastUpdatedAt: polledAt,
            }));
            const updatesByJob = new Map(updates.map((update) => [update.jobName, update]));
            const matchedUpdates = activeBuilds.map((build) => {
                const jobUpdate = updatesByJob.get(build.jobName);
                const candidateBuilds = jobUpdate?.builds || [];
                const matchedBuild = candidateBuilds.find((candidate) => candidate.number === build.buildNumber) ||
                    candidateBuilds.find((candidate) => {
                        if (!candidate.timestamp) {
                            return false;
                        }
                        const submittedAt = Date.parse(build.submittedAt || "");
                        const candidateTimestamp = Date.parse(candidate.timestamp);
                        return Number.isFinite(submittedAt) && candidateTimestamp >= submittedAt - 30000;
                    }) ||
                    candidateBuilds[0] ||
                    null;
                return {
                    id: build.id,
                    buildNumber: matchedBuild?.number ?? build.buildNumber ?? null,
                    jobUrl: matchedBuild?.url ?? build.jobUrl ?? "",
                    nextStatus: matchedBuild?.status ?? null,
                    errorMessage: jobUpdate?.errorMessage || "",
                    checkedAt: polledAt,
                    aborted: jobUpdate?.aborted || false,
                };
            });
            matchedUpdates.forEach((update) => {
                const previousBuild = previousBuildsById.get(update.id);
                if (!previousBuild ||
                    update.aborted ||
                    !update.nextStatus ||
                    previousBuild.status === update.nextStatus) {
                    return;
                }
                if (update.nextStatus === "SUCCESS") {
                    toast.success(`Build completed for ${previousBuild.projectName}.`);
                    addLog("status", `${previousBuild.projectName} completed`, "Green build.", update.nextStatus);
                }
                if (update.nextStatus === "RUNNING") {
                    addLog("status", `${previousBuild.projectName} running`, "Now running on the agent.", update.nextStatus);
                }
                if (update.nextStatus === "FAILED") {
                    toast.error(`Build failed for ${previousBuild.projectName}.`);
                    addLog("error", `${previousBuild.projectName} failed`, update.errorMessage || "Failed.", update.nextStatus);
                }
            });
            const updatesById = new Map(matchedUpdates.map((update) => [update.id, update]));
            setBuilds((currentBuilds) => currentBuilds.map((build) => {
                const update = updatesById.get(build.id);
                if (!update || update.aborted) {
                    return build;
                }
                return {
                    ...build,
                    buildNumber: update.buildNumber ?? build.buildNumber ?? null,
                    jobUrl: update.jobUrl || build.jobUrl || "",
                    status: update.nextStatus || build.status,
                    lastCheckedAt: update.checkedAt,
                    errorMessage: update.nextStatus ? "" : update.errorMessage || build.errorMessage || "",
                    statusHistory: update.nextStatus && update.nextStatus !== build.status
                        ? {
                            ...(build.statusHistory || {}),
                            [update.nextStatus]: update.checkedAt,
                        }
                        : build.statusHistory || createStatusHistory(build.status, build.lastCheckedAt || build.submittedAt),
                };
            }));
        }
        finally {
            if (pollAbortControllerRef.current === abortController) {
                pollAbortControllerRef.current = null;
            }
            isPollingRef.current = false;
            setPollMeta((currentMeta) => ({
                ...currentMeta,
                isPolling: false,
            }));
            if (isMountedRef.current && getActiveBuilds(buildsRef.current).length) {
                schedulePoll();
            }
        }
    }, [addLog, schedulePoll]);
    useEffect(() => {
        if (!filteredBuilds.length) {
            if (selectedBuildId) {
                setSelectedBuildId("");
            }
            return;
        }
        const stillExists = filteredBuilds.some((build) => build.id === selectedBuildId);
        if (!stillExists) {
            setSelectedBuildId(filteredBuilds[0].id);
        }
    }, [filteredBuilds, selectedBuildId]);
    useEffect(() => {
        if (!primaryBuild?.buildNumber) {
            setConsoleLog(null);
            return;
        }
        let isCancelled = false;
        async function loadLogs() {
            try {
                const response = await jenkinsUi.logs(primaryBuild.jobName, primaryBuild.buildNumber);
                if (isCancelled) {
                    return;
                }
                setConsoleLog({
                    buildId: response.id,
                    jobName: response.jobName || primaryBuild.jobName,
                    status: primaryBuild.status,
                    projectName: primaryBuild.projectName,
                    logs: response.logs || "",
                });
            }
            catch (error) {
                if (isCancelled) {
                    return;
                }
                setConsoleLog({
                    buildId: String(primaryBuild.buildNumber),
                    jobName: primaryBuild.jobName,
                    status: primaryBuild.status,
                    projectName: primaryBuild.projectName,
                    logs: error.message || "Unable to load Jenkins console logs.",
                });
            }
        }
        void loadLogs();
        return () => {
            isCancelled = true;
        };
    }, [
        primaryBuild?.buildNumber,
        primaryBuild?.jobName,
        primaryBuild?.projectName,
        primaryBuild?.status,
    ]);
    useEffect(() => {
        pollStatusesRef.current = pollStatuses;
    }, [pollStatuses]);
    useEffect(() => {
        isMountedRef.current = true;
        setBuilds(readStoredBuilds());
        hasRestoredBuilds.current = true;
        return () => {
            isMountedRef.current = false;
            stopPolling();
        };
    }, [stopPolling]);
    useEffect(() => {
        const intervalId = window.setInterval(() => {
            setNowTimestamp(Date.now());
        }, 1000);
        return () => {
            window.clearInterval(intervalId);
        };
    }, []);
    useEffect(() => {
        buildsRef.current = builds;
    }, [builds]);
    useEffect(() => {
        if (!hasRestoredBuilds.current || typeof window === "undefined") {
            return;
        }
        window.localStorage.setItem(STORAGE_KEY, JSON.stringify(builds));
    }, [builds]);
    useEffect(() => {
        if (!getActiveBuilds(builds).length) {
            stopPolling();
            return;
        }
        if (!pollTimeoutRef.current && !isPollingRef.current) {
            schedulePoll(0);
        }
    }, [builds, schedulePoll, stopPolling]);
    const buildStats = useMemo(() => {
        const waiting = builds.filter((build) => build.status === "QUEUED").length;
        const running = builds.filter((build) => build.status === "RUNNING").length;
        const success = builds.filter((build) => build.status === "SUCCESS").length;
        const failed = builds.filter((build) => build.status === "FAILED").length;
        return {
            total: builds.length,
            queued: waiting,
            running,
            success,
            failed,
        };
    }, [builds]);
    const autoRefreshIndicator = useMemo(() => {
        const hasActiveBuilds = getActiveBuilds(builds).length > 0;
        const nextRefreshAtMs = pollMeta.nextRefreshAt ? Date.parse(pollMeta.nextRefreshAt) : NaN;
        const secondsUntilRefresh = Number.isFinite(nextRefreshAtMs) && hasActiveBuilds
            ? Math.max(0, Math.ceil((nextRefreshAtMs - nowTimestamp) / 1000))
            : null;
        return {
            isActive: hasActiveBuilds,
            isPolling: pollMeta.isPolling,
            lastUpdatedLabel: formatClockTime(pollMeta.lastUpdatedAt),
            nextRefreshLabel: secondsUntilRefresh === null ? "-" : `${secondsUntilRefresh}s`,
        };
    }, [builds, nowTimestamp, pollMeta]);
    const analyzeTerminalBuild = useCallback(async (build) => {
        if (analyzingBuildIdsRef.current.has(build.id)) {
            return;
        }
        analyzingBuildIdsRef.current.add(build.id);
        try {
            let consoleOutput = "";
            if (build.buildNumber && build.jobName) {
                try {
                    const logResponse = await jenkinsUi.logs(build.jobName, build.buildNumber);
                    consoleOutput = logResponse?.logs || "";
                }
                catch {
                    consoleOutput = "";
                }
            }
            const result = await jenkinsUi.analyze({
                status: build.status,
                projectName: build.projectName,
                buildType: build.buildType,
                deliveryType: build.deliveryType,
                description: build.projectDescription,
                errorMessage: build.errorMessage,
                logs: consoleOutput,
            });
            if (!isMountedRef.current) {
                return;
            }
            setBuilds((currentBuilds) => currentBuilds.map((currentBuild) => currentBuild.id === build.id
                ? {
                    ...currentBuild,
                    analysis: result?.message || buildAnalysisFallback(build.status, build.projectName),
                    analysisSource: result?.source || "mock",
                    analysisNextStep: result?.nextStep || "",
                    analysisStage: result?.stage || "",
                }
                : currentBuild));
            addLog("ai", `${build.projectName} analyzed`, result?.nextStep || "See next step above.", build.status);
        }
        catch {
            if (!isMountedRef.current) {
                return;
            }
            setBuilds((currentBuilds) => currentBuilds.map((currentBuild) => currentBuild.id === build.id
                ? {
                    ...currentBuild,
                    analysis: buildAnalysisFallback(build.status, build.projectName),
                    analysisSource: "mock",
                    analysisNextStep: build.status === "SUCCESS"
                        ? "Ship or merge when ready."
                        : "Open the red stage in Jenkins and fix what broke.",
                    analysisStage: build.status === "SUCCESS" ? "Deploy (ArgoCD)" : "Build",
                }
                : currentBuild));
        }
        finally {
            analyzingBuildIdsRef.current.delete(build.id);
        }
    }, [addLog]);
    useEffect(() => {
        builds.forEach((build) => {
            const isTerminal = TERMINAL_STATUSES.has(build.status);
            if (!isTerminal || build.analysis) {
                return;
            }
            void analyzeTerminalBuild(build);
        });
    }, [analyzeTerminalBuild, builds]);
    async function handleSuggest(formValues) {
        setIsSuggesting(true);
        try {
            const suggestion = await jenkinsUi.suggest({
                description: formValues.projectDescription,
                currentValues: {
                    projectName: formValues.projectName,
                    buildType: formValues.buildType,
                    deliveryType: formValues.deliveryType,
                },
            });
            const nextValues = {
                ...formValues,
                projectName: suggestion.projectName || formValues.projectName,
                buildType: suggestion.buildType || formValues.buildType,
                deliveryType: suggestion.deliveryType || formValues.deliveryType,
            };
            setAiSuggestion(suggestion);
            setLastSubmittedValues(nextValues);
            addLog("ai", "Form filled from suggest", `${suggestion.buildTool || "build"} · ${suggestion.pipelineSteps?.length || 0} steps`, "READY");
            toast.success("Form updated.");
        }
        catch (error) {
            toast.error(error.message || "Unable to generate AI suggestions.");
        }
        finally {
            setIsSuggesting(false);
        }
    }
    async function handleBuildSubmit(formValues) {
        const jobName = resolveJobName(formValues);
        if (!jobName) {
            const message = "Project Name is required so the Jenkins job name can be resolved.";
            setFeedback({ type: "error", message });
            toast.error(message);
            return;
        }
        const buildRecord = {
            id: createBuildId(),
            jobName,
            ...formValues,
            status: "QUEUED",
            submittedAt: new Date().toISOString(),
            lastCheckedAt: null,
            errorMessage: "",
            analysis: "",
            analysisSource: "",
            analysisNextStep: "",
            analysisStage: "",
            buildNumber: null,
            queueId: "",
            jobUrl: "",
            statusHistory: createStatusHistory("QUEUED", new Date().toISOString()),
        };
        setIsSubmitting(true);
        setLastSubmittedValues(formValues);
        setFeedback(null);
        setBuilds((currentBuilds) => [buildRecord, ...currentBuilds]);
        addLog("request", `${formValues.projectName} queued`, `POST ${jobName}`, "QUEUED");
        try {
            const result = await jenkinsUi.trigger(jobName, toBuildParams(formValues));
            setBuilds((currentBuilds) => currentBuilds.map((build) => build.id === buildRecord.id
                ? {
                    ...build,
                    buildNumber: result.buildNumber ?? null,
                    queueId: result.queueId || "",
                    jobUrl: result.jobUrl || "",
                }
                : build));
            const message = `Build started for ${formValues.projectName}.`;
            setFeedback({ type: "success", message });
            toast.success(message);
            addLog("request", `${formValues.projectName} accepted`, "Queued; polling for number.", "QUEUED");
        }
        catch (error) {
            const message = error.message || "Failed to start the Jenkins build.";
            setBuilds((currentBuilds) => currentBuilds.map((build) => build.id === buildRecord.id
                ? {
                    ...build,
                    status: "FAILED",
                    errorMessage: message,
                    statusHistory: {
                        ...(build.statusHistory || {}),
                        FAILED: new Date().toISOString(),
                    },
                }
                : build));
            setFeedback({ type: "error", message });
            toast.error(message);
            addLog("error", `${formValues.projectName} request failed`, message, "FAILED");
        }
        finally {
            setIsSubmitting(false);
        }
    }
    return (<main className="mx-auto flex min-h-screen w-full max-w-7xl flex-col gap-6 px-4 py-8 sm:px-6 lg:px-8">
      <section className="rounded-3xl border border-border/80 bg-card/85 p-6 shadow-[0_20px_80px_rgba(0,0,0,0.2)] backdrop-blur xl:p-8">
        <div className="flex flex-col gap-6 xl:flex-row xl:items-end xl:justify-between">
          <div>
            <div className="inline-flex items-center gap-2 rounded-full border border-primary/20 bg-primary/10 px-3 py-1 text-xs font-medium text-primary">
              <Bot className="h-3.5 w-3.5"/>
              Jenkins lab
            </div>
            <h1 className="mt-4 text-3xl font-semibold tracking-tight text-foreground sm:text-4xl">
              Builds
            </h1>
            <p className="mt-3 max-w-3xl text-sm leading-6 text-muted sm:text-base">
              Fire a job, poll every few seconds, optional suggest/analyze from the OpenAI hook if you set the key.
            </p>
          </div>

          <div className="grid gap-3 sm:grid-cols-2">
            <div className="rounded-2xl border border-border/70 bg-background/45 p-4">
              <p className="text-xs uppercase tracking-[0.24em] text-muted">Polling</p>
              <p className="mt-2 flex items-center gap-2 text-sm font-medium text-foreground">
                <Clock3 className="h-4 w-4 text-primary"/>
                Every 3 seconds
              </p>
            </div>
            <div className="rounded-2xl border border-border/70 bg-background/45 p-4">
              <p className="text-xs uppercase tracking-[0.24em] text-muted">Backend API</p>
              <p className="mt-2 flex items-center gap-2 text-sm font-medium text-foreground">
                <Server className="h-4 w-4 text-primary"/>
                {API_TARGET}
              </p>
            </div>
          </div>
        </div>
        <div className="mt-6 grid gap-3 border-t border-border/70 pt-6 sm:grid-cols-3">
          <div className="rounded-2xl border border-border/70 bg-background/45 p-4">
            <p className="text-xs uppercase tracking-[0.24em] text-muted">Auto Refresh</p>
            <p className="mt-2 flex items-center gap-2 text-sm font-medium text-foreground">
              <span className={`h-2.5 w-2.5 rounded-full ${autoRefreshIndicator.isActive
            ? autoRefreshIndicator.isPolling
                ? "animate-pulse bg-primary"
                : "bg-success"
            : "bg-muted"}`}/>
              {autoRefreshIndicator.isActive
            ? autoRefreshIndicator.isPolling
                ? "Syncing now"
                : "Active"
            : "Paused"}
            </p>
          </div>
          <div className="rounded-2xl border border-border/70 bg-background/45 p-4">
            <p className="text-xs uppercase tracking-[0.24em] text-muted">Last Sync</p>
            <p className="mt-2 text-sm font-medium text-foreground">
              {autoRefreshIndicator.lastUpdatedLabel}
            </p>
          </div>
          <div className="rounded-2xl border border-border/70 bg-background/45 p-4">
            <p className="text-xs uppercase tracking-[0.24em] text-muted">Next Refresh</p>
            <p className="mt-2 text-sm font-medium text-foreground">
              {autoRefreshIndicator.nextRefreshLabel}
            </p>
          </div>
        </div>
      </section>

      <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
        <div className="rounded-2xl border border-border/80 bg-card/80 p-5 shadow-sm backdrop-blur">
          <p className="text-xs uppercase tracking-[0.24em] text-muted">Queued</p>
          <p className="mt-3 flex items-center gap-3 text-3xl font-semibold text-foreground">
            <Clock3 className="h-6 w-6 text-muted"/>
            {buildStats.queued}
          </p>
        </div>
        <div className="rounded-2xl border border-border/80 bg-card/80 p-5 shadow-sm backdrop-blur">
          <p className="text-xs uppercase tracking-[0.24em] text-muted">Running</p>
          <p className="mt-3 flex items-center gap-3 text-3xl font-semibold text-foreground">
            <Activity className="h-6 w-6 text-primary"/>
            {buildStats.running}
          </p>
        </div>
        <div className="rounded-2xl border border-border/80 bg-card/80 p-5 shadow-sm backdrop-blur">
          <p className="text-xs uppercase tracking-[0.24em] text-muted">Successful</p>
          <p className="mt-3 flex items-center gap-3 text-3xl font-semibold text-foreground">
            <CircleCheckBig className="h-6 w-6 text-success"/>
            {buildStats.success}
          </p>
        </div>
        <div className="rounded-2xl border border-border/80 bg-card/80 p-5 shadow-sm backdrop-blur">
          <p className="text-xs uppercase tracking-[0.24em] text-muted">Failed</p>
          <p className="mt-3 flex items-center gap-3 text-3xl font-semibold text-foreground">
            <XCircle className="h-6 w-6 text-danger"/>
            {buildStats.failed}
          </p>
        </div>
      </section>

      <BuildForm onSubmit={handleBuildSubmit} onSuggest={handleSuggest} isSubmitting={isSubmitting} isSuggesting={isSuggesting} initialValues={lastSubmittedValues} aiSuggestion={aiSuggestion}/>

      {feedback ? (<div className={`rounded-2xl border px-4 py-3 text-sm shadow-sm ${feedback.type === "success"
                ? "border-success/30 bg-success/10 text-success"
                : "border-danger/30 bg-danger/10 text-danger"}`}>
          {feedback.message}
        </div>) : null}

      <PipelineTimeline build={primaryBuild} currentTime={new Date(nowTimestamp).toISOString()} consoleLog={consoleLog}/>

      <BuildLogs logs={logs} consoleLog={consoleLog}/>

      <BuildTable builds={filteredBuilds} jobOptions={availableJobs} selectedJob={selectedJobFilter} onJobChange={setSelectedJobFilter} statusFilter={selectedStatusFilter} onStatusFilterChange={setSelectedStatusFilter} selectedBuildId={selectedBuildId} onSelectBuild={setSelectedBuildId}/>
    </main>);
}
