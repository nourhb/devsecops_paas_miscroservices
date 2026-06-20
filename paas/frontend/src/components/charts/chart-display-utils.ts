export const CHART_COLORS = {
    success: "#22c55e",
    warning: "#f59e0b",
    danger: "#ef4444",
    info: "#06b6d4",
    muted: "#64748b",
    purple: "#a855f7",
    indigo: "#6366f1",
    yellow: "#eab308"
};

export function chartYDomain(values: number[], floor = 1): [number, number] {
    return [0, Math.max(floor, ...values, 0)];
}

export function placeholderTimeSeries(points = 6, value = 0): Array<{ t: string; pct: number }> {
    const now = Date.now();
    return Array.from({ length: points }, (_, index) => ({
        t: new Date(now - (points - 1 - index) * 10 * 60 * 1000).toLocaleTimeString([], {
            hour: "2-digit",
            minute: "2-digit"
        }),
        pct: value
    }));
}

export type ChartPieRow = {
    name: string;
    value: number;
    fill: string;
};

export function pieRowsForDisplay<T extends ChartPieRow>(rows: T[], emptyLabel = "No data"): T[] {
    const total = rows.reduce((sum, row) => sum + row.value, 0);
    if (total > 0) {
        return rows;
    }
    return [{ name: emptyLabel, value: 1, fill: CHART_COLORS.muted } as T];
}

export function sumRowValues(rows: Array<{ value: number }>): number {
    return rows.reduce((sum, row) => sum + row.value, 0);
}

export function sumSeverityCounts(row: {
    critical: number;
    high: number;
    medium: number;
    low: number;
}): number {
    return row.critical + row.high + row.medium + row.low;
}

function argoStatusWeight(status?: string): number {
    const normalized = (status || "unknown").trim().toLowerCase();
    if (!normalized || normalized === "unknown" || normalized === "—" || normalized === "-") {
        return 0;
    }
    return 1;
}

export function argoHealthColor(health?: string): string {
    const normalized = (health || "").trim().toLowerCase();
    if (normalized === "healthy") {
        return CHART_COLORS.success;
    }
    if (normalized === "degraded" || normalized === "progressing") {
        return CHART_COLORS.warning;
    }
    if (normalized === "missing" || normalized === "suspended" || normalized.includes("fail")) {
        return CHART_COLORS.danger;
    }
    return CHART_COLORS.muted;
}

export function argoSyncColor(syncStatus?: string): string {
    const normalized = (syncStatus || "").trim().toLowerCase();
    if (normalized === "synced") {
        return CHART_COLORS.success;
    }
    if (normalized === "outofsync" || normalized === "out of sync") {
        return CHART_COLORS.warning;
    }
    return CHART_COLORS.muted;
}

export function argoGitOpsPieData(health?: string, syncStatus?: string): ChartPieRow[] {
    const healthLabel = health?.trim() || "Unknown";
    const syncLabel = syncStatus?.trim() || "Unknown";
    return pieRowsForDisplay([
        { name: `Health: ${healthLabel}`, value: argoStatusWeight(health), fill: argoHealthColor(health) },
        { name: `Sync: ${syncLabel}`, value: argoStatusWeight(syncStatus), fill: argoSyncColor(syncStatus) }
    ], "Argo CD pending");
}

export function supplyChainBarData(input: {
    signedImages: number;
    unsignedImages: number;
    failedBuilds: number;
    runningApplications: number;
}): ChartPieRow[] {
    return [
        { name: "Signed", value: input.signedImages, fill: CHART_COLORS.success },
        { name: "Unsigned", value: input.unsignedImages, fill: CHART_COLORS.warning },
        { name: "Failed builds", value: input.failedBuilds, fill: CHART_COLORS.danger },
        { name: "Running apps", value: input.runningApplications, fill: CHART_COLORS.info }
    ];
}
