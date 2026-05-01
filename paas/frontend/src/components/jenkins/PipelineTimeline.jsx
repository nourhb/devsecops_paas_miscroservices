"use client";

import { Activity, CircleCheckBig, Clock3, Search, ShieldCheck, ShipWheel, TestTube2, Timer, Wrench, XCircle } from "lucide-react";

const TIMELINE_STEPS = [
  {
    id: "QUEUED",
    label: "Queued",
    description: "Jenkins accepted the request.",
    icon: Clock3,
    activeClassName: "border-border bg-muted/10 text-foreground",
    dotClassName: "bg-muted",
  },
  {
    id: "RUNNING",
    label: "Running",
    description: "Pipeline is executing.",
    icon: Activity,
    activeClassName: "border-primary/30 bg-primary/10 text-primary",
    dotClassName: "bg-primary",
  },
  {
    id: "SUCCESS",
    label: "Success",
    description: "Build completed successfully.",
    icon: CircleCheckBig,
    activeClassName: "border-success/30 bg-success/10 text-success",
    dotClassName: "bg-success",
  },
  {
    id: "FAILED",
    label: "Failed",
    description: "Build ended in a failed state.",
    icon: XCircle,
    activeClassName: "border-danger/30 bg-danger/10 text-danger",
    dotClassName: "bg-danger",
  },
];

const PIPELINE_FLOW_STEPS = [
  {
    id: "BUILD",
    label: "Build",
    icon: Wrench,
    keywords: [" build ", "mvn package", "mvn clean install", "npm run build", "gradle build"],
  },
  {
    id: "TEST",
    label: "Test",
    icon: TestTube2,
    keywords: [" test ", "unit test", "integration test", "npm test", "mvn test", "gradle test"],
  },
  {
    id: "SONARQUBE",
    label: "SonarQube",
    icon: Search,
    keywords: ["sonarqube", "sonar-scanner", "sonar scan", "quality gate"],
  },
  {
    id: "DEPENDENCY_CHECK",
    label: "Dependency Check",
    icon: ShieldCheck,
    keywords: ["dependency-check", "owasp", "dependency check", "vulnerability scan"],
  },
  {
    id: "DOCKER",
    label: "Docker",
    icon: Activity,
    keywords: ["docker build", "docker push", "image push", "container image"],
  },
  {
    id: "DEPLOY",
    label: "Deploy (ArgoCD)",
    icon: ShipWheel,
    keywords: ["argocd", "argo cd", "kubectl apply", "deployment rollout", "sync status"],
  },
];

function getStepState(stepId, currentStatus) {
  const status = currentStatus || "QUEUED";

  if (status === "QUEUED") {
    return stepId === "QUEUED" ? "active" : "pending";
  }

  if (status === "RUNNING") {
    if (stepId === "QUEUED") {
      return "complete";
    }

    return stepId === "RUNNING" ? "active" : "pending";
  }

  if (status === "SUCCESS") {
    if (stepId === "QUEUED" || stepId === "RUNNING") {
      return "complete";
    }

    return stepId === "SUCCESS" ? "active" : "pending";
  }

  if (status === "FAILED") {
    if (stepId === "QUEUED" || stepId === "RUNNING") {
      return "complete";
    }

    return stepId === "FAILED" ? "active" : "pending";
  }

  return "pending";
}

function getCardClassName(step, state) {
  if (state === "active") {
    return step.activeClassName;
  }

  if (state === "complete") {
    return "border-success/20 bg-success/5 text-foreground";
  }

  return "border-border/70 bg-background/35 text-muted";
}

function formatStepTimestamp(timestamp) {
  if (!timestamp) {
    return "Waiting";
  }

  return new Date(timestamp).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

function formatDetailTimestamp(timestamp) {
  if (!timestamp) {
    return "-";
  }

  return new Date(timestamp).toLocaleString([], {
    year: "numeric",
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

function formatDuration(startTimestamp, endTimestamp) {
  if (!startTimestamp || !endTimestamp) {
    return "-";
  }

  const startMs = Date.parse(startTimestamp);
  const endMs = Date.parse(endTimestamp);

  if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs < startMs) {
    return "-";
  }

  const totalSeconds = Math.floor((endMs - startMs) / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;

  if (hours > 0) {
    return `${hours}h ${remainingMinutes}m ${seconds}s`;
  }

  return `${minutes}m ${seconds}s`;
}

function normalizeLogText(consoleLog) {
  return ` ${String(consoleLog?.logs || "").toLowerCase()} `;
}

function getPipelineFlowStatuses(build, consoleLog) {
  const logText = normalizeLogText(consoleLog);
  const matchedIndexes = PIPELINE_FLOW_STEPS.map((step, index) =>
    step.keywords.some((keyword) => logText.includes(keyword.toLowerCase())) ? index : -1
  ).filter((index) => index >= 0);
  const lastMatchedIndex = matchedIndexes.length ? Math.max(...matchedIndexes) : -1;
  const firstActiveIndex =
    build?.status === "RUNNING"
      ? lastMatchedIndex >= 0
        ? lastMatchedIndex
        : 0
      : build?.status === "QUEUED"
        ? 0
        : -1;
  const failedIndex =
    build?.status === "FAILED"
      ? lastMatchedIndex >= 0
        ? lastMatchedIndex
        : 0
      : -1;

  return PIPELINE_FLOW_STEPS.map((step, index) => {
    if (build?.status === "SUCCESS") {
      return {
        ...step,
        status: "SUCCESS",
        detail: "Completed",
      };
    }

    if (build?.status === "FAILED") {
      if (index < failedIndex) {
        return {
          ...step,
          status: "SUCCESS",
          detail: "Completed before failure",
        };
      }

      if (index === failedIndex) {
        return {
          ...step,
          status: "FAILED",
          detail: "Latest failing stage inferred from Jenkins output",
        };
      }

      return {
        ...step,
        status: "PENDING",
        detail: "Not reached",
      };
    }

    if (build?.status === "RUNNING") {
      if (index < firstActiveIndex) {
        return {
          ...step,
          status: "SUCCESS",
          detail: "Completed",
        };
      }

      if (index === firstActiveIndex) {
        return {
          ...step,
          status: "RUNNING",
          detail: consoleLog?.logs ? "Active stage inferred from Jenkins output" : "Pipeline in progress",
        };
      }

      return {
        ...step,
        status: "PENDING",
        detail: "Waiting",
      };
    }

    if (build?.status === "QUEUED") {
      return {
        ...step,
        status: index === 0 ? "QUEUED" : "PENDING",
        detail: index === 0 ? "Ready to start" : "Waiting",
      };
    }

    return {
      ...step,
      status: "PENDING",
      detail: "Waiting",
    };
  });
}

function getFlowStatusClasses(status) {
  if (status === "SUCCESS") {
    return "border-success/30 bg-success/10 text-success";
  }

  if (status === "RUNNING") {
    return "border-primary/30 bg-primary/10 text-primary";
  }

  if (status === "FAILED") {
    return "border-danger/30 bg-danger/10 text-danger";
  }

  if (status === "QUEUED") {
    return "border-border/70 bg-muted/10 text-foreground";
  }

  return "border-border/70 bg-background/50 text-muted";
}

export default function PipelineTimeline({ build, currentTime, consoleLog }) {
  const queuedAt = build?.statusHistory?.QUEUED || build?.submittedAt || "";
  const completedAt =
    build?.status === "SUCCESS"
      ? build?.statusHistory?.SUCCESS || build?.lastCheckedAt || ""
      : build?.status === "FAILED"
        ? build?.statusHistory?.FAILED || build?.lastCheckedAt || ""
        : currentTime;
  const elapsedDuration = build
    ? formatDuration(queuedAt, completedAt)
    : "-";
  const startedAtLabel = formatDetailTimestamp(queuedAt);
  const finishedAtLabel = formatDetailTimestamp(
    build?.status === "SUCCESS" || build?.status === "FAILED" ? completedAt : ""
  );
  const pipelineFlowStatuses = build ? getPipelineFlowStatuses(build, consoleLog) : [];

  return (
    <section className="rounded-3xl border border-border/80 bg-card/85 p-6 shadow-[0_20px_80px_rgba(0,0,0,0.18)] backdrop-blur">
      <div className="mb-5 flex flex-col gap-3 border-b border-border/70 pb-5 md:flex-row md:items-center md:justify-between">
        <div>
          <h2 className="text-xl font-semibold text-foreground">Real-Time Pipeline Status</h2>
          <p className="mt-1 text-sm text-muted">
            Live timeline for the selected Jenkins build, updated every 3 seconds.
          </p>
        </div>
        <div className="rounded-xl border border-border/70 bg-background/40 px-4 py-3 text-sm text-muted">
          Current: <span className="font-semibold text-foreground">{build?.status || "QUEUED"}</span>
        </div>
      </div>

      {build ? (
        <>
          <div className="mb-5 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
            <div className="rounded-2xl border border-border/70 bg-background/35 p-4">
              <p className="text-xs uppercase tracking-[0.24em] text-muted">Project</p>
              <p className="mt-2 font-medium text-foreground">{build.projectName}</p>
            </div>
            <div className="rounded-2xl border border-border/70 bg-background/35 p-4">
              <p className="text-xs uppercase tracking-[0.24em] text-muted">Jenkins Job</p>
              <p className="mt-2 font-medium text-foreground">{build.jobName}</p>
            </div>
            <div className="rounded-2xl border border-border/70 bg-background/35 p-4">
              <p className="text-xs uppercase tracking-[0.24em] text-muted">Build Number</p>
              <p className="mt-2 font-medium text-foreground">{build.buildNumber ?? "Pending assignment"}</p>
            </div>
            <div className="rounded-2xl border border-border/70 bg-background/35 p-4">
              <p className="text-xs uppercase tracking-[0.24em] text-muted">Elapsed</p>
              <p className="mt-2 flex items-center gap-2 font-medium text-foreground">
                <Timer className="h-4 w-4 text-primary" />
                {elapsedDuration}
              </p>
              <div className="mt-3 space-y-1 text-xs text-muted">
                <p>Started At: {startedAtLabel}</p>
                <p>Finished At: {finishedAtLabel}</p>
              </div>
            </div>
          </div>

          <div className="grid gap-4 xl:grid-cols-4">
            {TIMELINE_STEPS.map((step, index) => {
              const state = getStepState(step.id, build.status);
              const Icon = step.icon;
              const isRunning = step.id === "RUNNING" && state === "active";
              const nextStep = TIMELINE_STEPS[index + 1];
              const nextStepState = nextStep ? getStepState(nextStep.id, build.status) : "pending";
              const connectorIsActive = state === "active" && nextStepState === "pending";
              const connectorIsComplete = state === "complete";
              const reachedAt = build.statusHistory?.[step.id] || "";

              return (
                <div key={step.id} className="relative">
                  {index < TIMELINE_STEPS.length - 1 ? (
                    <div className="absolute left-[calc(100%-0.5rem)] top-8 hidden h-0.5 w-[calc(100%+1rem)] overflow-hidden rounded-full bg-border/70 xl:block">
                      <div
                        className={`h-full rounded-full transition-all ${
                          connectorIsComplete
                            ? "w-full bg-success"
                            : connectorIsActive
                              ? "w-full animate-pulse bg-primary"
                              : "w-0"
                        }`}
                      />
                    </div>
                  ) : null}
                  <div
                    className={`rounded-2xl border p-4 transition ${getCardClassName(step, state)}`}
                  >
                    <div className="flex items-center gap-3">
                      <div
                        className={`flex h-10 w-10 items-center justify-center rounded-xl ${
                          state === "pending" ? "bg-background/70" : step.activeClassName
                        }`}
                      >
                        {isRunning ? (
                          <span className="h-4 w-4 animate-spin rounded-full border-2 border-current/30 border-t-current" />
                        ) : (
                          <Icon className="h-5 w-5" />
                        )}
                      </div>
                      <div>
                        <p className="text-sm font-semibold">{step.label}</p>
                        <p className="text-xs text-muted">{step.description}</p>
                        <p className="mt-1 text-xs text-muted">
                          {formatStepTimestamp(reachedAt)}
                        </p>
                      </div>
                    </div>
                    <div className="mt-4 flex items-center gap-2">
                      <span
                        className={`h-2.5 w-2.5 rounded-full ${
                          state === "active"
                            ? step.dotClassName
                            : state === "complete"
                              ? "bg-success"
                              : "bg-border"
                        }`}
                      />
                      <span className="text-xs uppercase tracking-[0.24em] text-muted">
                        {state === "active"
                          ? "Current"
                          : state === "complete"
                            ? "Complete"
                            : "Pending"}
                      </span>
                    </div>
                  </div>
                </div>
              );
            })}
          </div>

          <div className="mt-6 rounded-2xl border border-border/70 bg-background/25 p-4">
            <div className="mb-4 flex items-center justify-between gap-3">
              <div>
                <h3 className="text-base font-semibold text-foreground">Full Pipeline Flow</h3>
                <p className="mt-1 text-sm text-muted">
                  Build, test, scan, package, and deploy stages inferred from the selected Jenkins run.
                </p>
              </div>
            </div>

            <div className="overflow-x-auto rounded-2xl border border-border/70 bg-background/40">
              <table className="w-full min-w-[640px] border-collapse text-left text-sm">
                <thead>
                  <tr className="border-b border-border/70 bg-background/70">
                    <th className="px-4 py-3 text-xs font-semibold uppercase tracking-[0.24em] text-muted">Step</th>
                    <th className="px-4 py-3 text-xs font-semibold uppercase tracking-[0.24em] text-muted">Status</th>
                    <th className="px-4 py-3 text-xs font-semibold uppercase tracking-[0.24em] text-muted">Details</th>
                  </tr>
                </thead>
                <tbody>
                  {pipelineFlowStatuses.map((step) => {
                    const Icon = step.icon;

                    return (
                      <tr key={step.id} className="border-b border-border/60 last:border-b-0">
                        <td className="px-4 py-4">
                          <div className="flex items-center gap-3">
                            <div className="rounded-xl border border-border/70 bg-background/60 p-2">
                              <Icon className="h-4 w-4 text-primary" />
                            </div>
                            <span className="font-medium text-foreground">{step.label}</span>
                          </div>
                        </td>
                        <td className="px-4 py-4">
                          <span
                            className={`inline-flex min-w-28 items-center justify-center gap-2 rounded-full border px-3 py-1.5 text-xs font-semibold ${getFlowStatusClasses(step.status)}`}
                          >
                            {step.status === "RUNNING" ? (
                              <span className="h-3 w-3 animate-spin rounded-full border-2 border-current/30 border-t-current" />
                            ) : null}
                            {step.status}
                          </span>
                        </td>
                        <td className="px-4 py-4 text-muted">{step.detail}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          </div>
        </>
      ) : (
        <div className="rounded-2xl border border-dashed border-border/70 bg-background/25 px-4 py-12 text-center text-sm text-muted">
          No build selected yet. Trigger a pipeline or choose a build from the history table.
        </div>
      )}
    </section>
  );
}
