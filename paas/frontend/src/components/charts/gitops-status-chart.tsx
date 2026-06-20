"use client";
import { Cell, Legend, Pie, PieChart, ResponsiveContainer, Tooltip } from "recharts";
import { ChartCaption, ChartStatRow } from "@/components/charts/chart-stat-row";
import { argoGitOpsPieData } from "@/components/charts/chart-display-utils";

export function GitOpsStatusChart({ health, syncStatus, appName, unreachableReason, className }: {
    health?: string;
    syncStatus?: string;
    appName?: string;
    unreachableReason?: string;
    className?: string;
}) {
    const pieData = argoGitOpsPieData(health, syncStatus);
    const healthLabel = health?.trim() || "Unknown";
    const syncLabel = syncStatus?.trim() || "Unknown";
    return (<div className={className}>
      <ChartStatRow items={[
            { label: "App", value: appName?.trim() || "—" },
            { label: "Health", value: healthLabel },
            { label: "Sync", value: syncLabel }
        ]}/>
      <div className="h-[160px]">
        <ResponsiveContainer width="100%" height="100%">
          <PieChart>
            <Pie data={pieData} dataKey="value" nameKey="name" cx="50%" cy="50%" innerRadius={46} outerRadius={68}>
              {pieData.map((entry) => <Cell key={entry.name} fill={entry.fill}/>)}
            </Pie>
            <Tooltip contentStyle={{ background: "hsl(var(--card))", border: "1px solid hsl(var(--border))", borderRadius: 12 }}/>
            <Legend wrapperStyle={{ fontSize: 11 }}/>
          </PieChart>
        </ResponsiveContainer>
      </div>
      {unreachableReason ? (<ChartCaption className="text-warning">
          {unreachableReason}
        </ChartCaption>) : (<ChartCaption>
          {healthLabel === "Unknown" && syncLabel === "Unknown"
              ? "Configure ARGOCD_BASE_URL and ARGOCD_AUTH_TOKEN (or password) for live GitOps status."
              : "GitOps health and sync state for this application."}
        </ChartCaption>)}
    </div>);
}
