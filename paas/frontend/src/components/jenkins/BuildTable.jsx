"use client";

import { Activity, BrainCircuit, CircleCheckBig, Clock3, Logs, XCircle } from "lucide-react";

const FLOW_STEPS = [
  "Build",
  "Test",
  "SonarQube",
  "Dependency Check",
  "Docker",
  "Deploy (ArgoCD)",
];

const STATUS_STYLES = {
  PENDING: "border border-border/70 bg-background/40 text-muted",
  QUEUED: "border border-border bg-muted/10 text-muted",
  RUNNING: "border border-primary/30 bg-primary/10 text-primary",
  SUCCESS: "border border-success/30 bg-success/10 text-success",
  FAILED: "border border-danger/30 bg-danger/10 text-danger",
};

const STATUS_ICONS = {
  PENDING: Clock3,
  QUEUED: Clock3,
  RUNNING: Activity,
  SUCCESS: CircleCheckBig,
  FAILED: XCircle,
};

function StatusBadge({ status }) {
  const normalizedStatus = status || "QUEUED";
  const Icon = STATUS_ICONS[normalizedStatus] || Clock3;

  return (
    <span
      className={`inline-flex min-w-28 items-center justify-center gap-2 rounded-full px-3 py-1.5 text-xs font-semibold ${STATUS_STYLES[normalizedStatus] || STATUS_STYLES.QUEUED}`}
    >
      {normalizedStatus === "RUNNING" ? (
        <span className="h-3 w-3 animate-spin rounded-full border-2 border-current/30 border-t-current" />
      ) : (
        <Icon className="h-3.5 w-3.5" />
      )}
      {normalizedStatus}
    </span>
  );
}

function normalizeStageKey(stageLabel) {
  return String(stageLabel || "").trim().toLowerCase();
}

function getFlowPreview(build) {
  const matchedStage = normalizeStageKey(build.analysisStage);

  return FLOW_STEPS.map((step, index) => {
    const stepKey = normalizeStageKey(step);

    if (build.status === "SUCCESS") {
      return { step, status: "SUCCESS" };
    }

    if (build.status === "FAILED") {
      if (matchedStage && stepKey === matchedStage) {
        return { step, status: "FAILED" };
      }

      if (matchedStage) {
        const matchedIndex = FLOW_STEPS.findIndex(
          (candidate) => normalizeStageKey(candidate) === matchedStage
        );

        if (matchedIndex >= 0 && index < matchedIndex) {
          return { step, status: "SUCCESS" };
        }

        if (matchedIndex >= 0 && index > matchedIndex) {
          return { step, status: "PENDING" };
        }
      }

      return { step, status: index === 0 ? "FAILED" : "PENDING" };
    }

    if (build.status === "RUNNING") {
      return { step, status: index === 0 ? "RUNNING" : "PENDING" };
    }

    if (build.status === "QUEUED") {
      return { step, status: index === 0 ? "QUEUED" : "PENDING" };
    }

    return { step, status: "PENDING" };
  });
}

export default function BuildTable({
  builds,
  jobOptions,
  selectedJob,
  onJobChange,
  statusFilter,
  onStatusFilterChange,
  selectedBuildId,
  onSelectBuild,
}) {
  return (
    <section className="rounded-3xl border border-border/80 bg-card/85 p-6 shadow-[0_20px_80px_rgba(0,0,0,0.18)] backdrop-blur">
      <div className="mb-5 flex flex-col gap-4 border-b border-border/70 pb-5 md:flex-row md:items-center md:justify-between">
        <div>
          <h2 className="text-xl font-semibold text-foreground">Pipeline Activity</h2>
          <p className="mt-1 text-sm text-muted">
            Live build status stays in sync with Jenkins, and the latest state is restored after refresh.
          </p>
        </div>
        <div className="rounded-xl border border-border/70 bg-background/40 px-4 py-3 text-sm text-muted">
          Total Builds: <span className="font-semibold text-foreground">{builds.length}</span>
        </div>
      </div>

      <div className="mb-5 grid gap-3 md:grid-cols-2">
        <label className="block">
          <span className="text-xs uppercase tracking-[0.24em] text-muted">Job Filter</span>
          <select
            value={selectedJob}
            onChange={(event) => onJobChange(event.target.value)}
            className="mt-2 flex h-11 w-full rounded-xl border border-border/70 bg-background/60 px-3 text-sm text-foreground outline-none transition focus:border-primary/50"
          >
            <option value="all">All jobs</option>
            {jobOptions.map((job) => (
              <option key={job} value={job}>
                {job}
              </option>
            ))}
          </select>
        </label>
        <label className="block">
          <span className="text-xs uppercase tracking-[0.24em] text-muted">Status Filter</span>
          <select
            value={statusFilter}
            onChange={(event) => onStatusFilterChange(event.target.value)}
            className="mt-2 flex h-11 w-full rounded-xl border border-border/70 bg-background/60 px-3 text-sm text-foreground outline-none transition focus:border-primary/50"
          >
            <option value="all">All statuses</option>
            <option value="QUEUED">Queued</option>
            <option value="RUNNING">Running</option>
            <option value="SUCCESS">Success</option>
            <option value="FAILED">Failed</option>
          </select>
        </label>
      </div>

      <div className="overflow-x-auto rounded-2xl border border-border/70 bg-background/30">
        <table className="w-full min-w-[1320px] border-collapse text-left text-sm">
          <thead>
            <tr className="border-b border-border/70 bg-background/80">
              <th className="px-4 py-3 text-xs font-semibold uppercase tracking-[0.24em] text-muted">Position</th>
              <th className="px-4 py-3 text-xs font-semibold uppercase tracking-[0.24em] text-muted">PGN</th>
              <th className="px-4 py-3 text-xs font-semibold uppercase tracking-[0.24em] text-muted">PN</th>
              <th className="px-4 py-3 text-xs font-semibold uppercase tracking-[0.24em] text-muted">PT</th>
              <th className="px-4 py-3 text-xs font-semibold uppercase tracking-[0.24em] text-muted">BT</th>
              <th className="px-4 py-3 text-xs font-semibold uppercase tracking-[0.24em] text-muted">Email</th>
              <th className="px-4 py-3 text-xs font-semibold uppercase tracking-[0.24em] text-muted">DT</th>
              <th className="px-4 py-3 text-xs font-semibold uppercase tracking-[0.24em] text-muted">Status</th>
              <th className="px-4 py-3 text-xs font-semibold uppercase tracking-[0.24em] text-muted">Flow</th>
              <th className="px-4 py-3 text-xs font-semibold uppercase tracking-[0.24em] text-muted">AI Insight</th>
              <th className="px-4 py-3 text-xs font-semibold uppercase tracking-[0.24em] text-muted">Logs</th>
            </tr>
          </thead>

          <tbody>
            {builds.length ? (
              builds.map((build, index) => {
                const flowPreview = getFlowPreview(build);

                return (
                  <tr
                    key={build.id}
                    className={`border-b border-border/60 align-top transition hover:bg-background/60 ${
                      build.id === selectedBuildId ? "bg-background/60" : ""
                    }`}
                  >
                    <td className="px-4 py-4 text-foreground">{index + 1}</td>
                    <td className="px-4 py-4 text-foreground">{build.projectGroupName}</td>
                    <td className="px-4 py-4 font-medium text-foreground">{build.projectName}</td>
                    <td className="px-4 py-4 text-foreground">{build.projectTag}</td>
                    <td className="px-4 py-4 text-foreground">{build.buildType}</td>
                    <td className="px-4 py-4 text-foreground">{build.email}</td>
                    <td className="px-4 py-4 text-foreground">{build.deliveryType}</td>
                    <td className="px-4 py-4">
                      <StatusBadge status={build.status} />
                    </td>
                    <td className="px-4 py-4">
                      <div className="grid gap-2">
                        {flowPreview.map((step) => (
                          <div
                            key={`${build.id}-${step.step}`}
                            className="flex items-center justify-between gap-3 rounded-lg border border-border/60 bg-background/40 px-3 py-2"
                          >
                            <span className="text-xs font-medium text-foreground">{step.step}</span>
                            <StatusBadge status={step.status} />
                          </div>
                        ))}
                      </div>
                    </td>
                    <td className="px-4 py-4 text-muted">
                      {build.analysis ? (
                        <div className="rounded-xl border border-border/60 bg-background/40 p-3">
                          <p className="flex items-start gap-2 text-foreground">
                            <BrainCircuit className="mt-0.5 h-4 w-4 shrink-0 text-primary" />
                            <span>{build.analysis}</span>
                          </p>
                          {build.analysisStage ? (
                            <p className="mt-2 text-sm text-muted">Stage: {build.analysisStage}</p>
                          ) : null}
                          {build.analysisNextStep ? (
                            <p className="mt-2 text-sm text-muted">
                              Next: {build.analysisNextStep}
                            </p>
                          ) : null}
                          <p className="mt-2 text-xs uppercase tracking-[0.24em] text-muted">
                            {build.analysisSource || "Pipeline Analyzer"}
                          </p>
                        </div>
                      ) : (
                        <span>{build.status === "SUCCESS" || build.status === "FAILED" ? "Analyzing..." : "-"}</span>
                      )}
                    </td>
                    <td className="px-4 py-4">
                      <button
                        type="button"
                        onClick={() => onSelectBuild(build.id)}
                        className="inline-flex items-center gap-2 rounded-xl border border-border/70 bg-background/60 px-3 py-2 text-xs font-medium text-foreground transition hover:border-primary/40 hover:bg-background"
                      >
                        <Logs className="h-3.5 w-3.5" />
                        {build.id === selectedBuildId ? "Viewing" : "View"}
                      </button>
                    </td>
                  </tr>
                );
              })
            ) : (
              <tr>
                <td colSpan="11" className="px-4 py-14 text-center text-sm text-muted">
                  No builds submitted yet. Trigger a build to start the live activity feed.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}
