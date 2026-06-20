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
