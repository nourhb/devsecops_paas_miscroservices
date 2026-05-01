"use client";

import { useState } from "react";
import { Activity, Bot, Clock3, FileText, TerminalSquare, TriangleAlert } from "lucide-react";

const LOG_ICON_BY_TYPE = {
  status: Activity,
  ai: Bot,
  request: Clock3,
  error: TriangleAlert,
};

function formatTime(timestamp) {
  if (!timestamp) {
    return "-";
  }

  return new Date(timestamp).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

export default function BuildLogs({ logs, consoleLog }) {
  const [isExpanded, setIsExpanded] = useState(false);

  return (
    <>
      <section className="rounded-3xl border border-border/80 bg-card/85 p-6 shadow-[0_20px_80px_rgba(0,0,0,0.18)] backdrop-blur">
        <div className="mb-5 flex items-center justify-between gap-4 border-b border-border/70 pb-5">
          <div>
            <h2 className="text-xl font-semibold text-foreground">Pipeline Logs</h2>
            <p className="mt-1 text-sm text-muted">
              Recent orchestration events from build triggers, polling updates, and AI analysis.
            </p>
          </div>
          <div className="rounded-xl border border-border/70 bg-background/40 px-4 py-3 text-sm text-muted">
            Events: <span className="font-semibold text-foreground">{logs.length}</span>
          </div>
        </div>

        <div className="mb-5 rounded-2xl border border-border/70 bg-background/30 p-4">
          <div className="flex items-center justify-between gap-4">
            <div className="flex items-center gap-2">
              <TerminalSquare className="h-4 w-4 text-primary" />
              <p className="font-medium text-foreground">Jenkins Console Output</p>
            </div>
            <button
              type="button"
              onClick={() => setIsExpanded(true)}
              disabled={!consoleLog}
              className="rounded-xl border border-border/70 bg-background/60 px-3 py-2 text-xs font-medium text-foreground transition hover:border-primary/40 hover:bg-background disabled:cursor-not-allowed disabled:opacity-50"
            >
              Open Full Log
            </button>
          </div>
          {consoleLog ? (
            <>
              <p className="mt-2 text-sm text-muted">
                {consoleLog.projectName} · {consoleLog.jobName} #{consoleLog.buildId} · {consoleLog.status}
              </p>
              <pre className="mt-4 max-h-72 overflow-auto rounded-2xl border border-border/60 bg-background/80 p-4 text-xs leading-6 text-foreground">
                {consoleLog.logs || "No console output yet."}
              </pre>
            </>
          ) : (
            <div className="mt-4 rounded-2xl border border-dashed border-border/70 bg-background/25 px-4 py-10 text-center text-sm text-muted">
              Build logs will appear here after Jenkins assigns a build number.
            </div>
          )}
        </div>

        <div className="space-y-3">
          {logs.length ? (
            logs.map((log) => {
              const Icon = LOG_ICON_BY_TYPE[log.type] || FileText;

              return (
                <div
                  key={log.id}
                  className="rounded-2xl border border-border/60 bg-background/35 p-4 transition hover:bg-background/50"
                >
                  <div className="flex items-start gap-3">
                    <div className="rounded-xl border border-border/70 bg-background/60 p-2">
                      <Icon className="h-4 w-4 text-primary" />
                    </div>
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <p className="font-medium text-foreground">{log.title}</p>
                        <span className="rounded-full border border-border/70 px-2 py-0.5 text-[11px] uppercase tracking-[0.24em] text-muted">
                          {log.type}
                        </span>
                        {log.status ? (
                          <span className="rounded-full border border-border/70 px-2 py-0.5 text-[11px] uppercase tracking-[0.24em] text-muted">
                            {log.status}
                          </span>
                        ) : null}
                      </div>
                      <p className="mt-1 text-sm text-muted">{log.message}</p>
                    </div>
                    <div className="text-xs text-muted">{formatTime(log.timestamp)}</div>
                  </div>
                </div>
              );
            })
          ) : (
            <div className="rounded-2xl border border-dashed border-border/70 bg-background/25 px-4 py-10 text-center text-sm text-muted">
              No pipeline events yet. Trigger a build to populate the activity log.
            </div>
          )}
        </div>
      </section>

      {isExpanded && consoleLog ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4 backdrop-blur-sm">
          <div className="flex h-[85vh] w-full max-w-6xl flex-col rounded-3xl border border-border/80 bg-card p-5 shadow-2xl">
            <div className="flex items-center justify-between gap-4 border-b border-border/70 pb-4">
              <div>
                <h3 className="text-lg font-semibold text-foreground">Full Jenkins Console Log</h3>
                <p className="mt-1 text-sm text-muted">
                  {consoleLog.projectName} · {consoleLog.jobName} #{consoleLog.buildId} · {consoleLog.status}
                </p>
              </div>
              <button
                type="button"
                onClick={() => setIsExpanded(false)}
                className="rounded-xl border border-border/70 bg-background/60 px-3 py-2 text-sm font-medium text-foreground transition hover:border-primary/40 hover:bg-background"
              >
                Close
              </button>
            </div>
            <pre className="mt-4 flex-1 overflow-auto rounded-2xl border border-border/60 bg-background/80 p-4 text-xs leading-6 text-foreground">
              {consoleLog.logs || "No console output yet."}
            </pre>
          </div>
        </div>
      ) : null}
    </>
  );
}
