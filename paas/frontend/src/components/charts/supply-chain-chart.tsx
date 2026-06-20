"use client";
import { Bar, BarChart, CartesianGrid, Cell, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { ChartCaption, ChartStatRow } from "@/components/charts/chart-stat-row";
import { chartYDomain, sumRowValues, supplyChainBarData } from "@/components/charts/chart-display-utils";

export function SupplyChainChart({ signedImages, unsignedImages, failedBuilds, runningApplications, className }: {
    signedImages: number;
    unsignedImages: number;
    failedBuilds: number;
    runningApplications: number;
    className?: string;
}) {
    const rows = supplyChainBarData({ signedImages, unsignedImages, failedBuilds, runningApplications });
    const max = Math.max(...rows.map((row) => row.value), 0);
    return (<div className={className}>
      <ChartStatRow items={rows.map((row) => ({ label: row.name, value: row.value }))}/>
      <div className="h-[180px]">
        <ResponsiveContainer width="100%" height="100%">
          <BarChart data={rows} margin={{ left: -12, right: 8, top: 8, bottom: 4 }}>
            <CartesianGrid strokeDasharray="3 3" stroke="hsl(var(--border))" vertical={false}/>
            <XAxis dataKey="name" tick={{ fontSize: 10, fill: "hsl(var(--muted-foreground))" }} tickLine={false} axisLine={false}/>
            <YAxis allowDecimals={false} domain={chartYDomain(rows.map((row) => row.value))} tick={{ fontSize: 10, fill: "hsl(var(--muted-foreground))" }} tickLine={false} axisLine={false}/>
            <Tooltip contentStyle={{ background: "hsl(var(--card))", border: "1px solid hsl(var(--border))", borderRadius: 12 }}/>
            <Bar dataKey="value" radius={[6, 6, 0, 0]}>
              {rows.map((entry) => <Cell key={entry.name} fill={entry.fill}/>)}
            </Bar>
          </BarChart>
        </ResponsiveContainer>
      </div>
      <ChartCaption>
        {sumRowValues(rows) === 0
            ? "Workspace rollups are 0 — trigger builds/deploys to populate supply-chain metrics."
            : "Workspace-wide Cosign and deployment rollups (all projects)."}
      </ChartCaption>
    </div>);
}
