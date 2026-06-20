import { cn } from "@/lib/utils";

export function ChartStatRow({ items, className }: {
    items: Array<{ label: string; value: string | number }>;
    className?: string;
}) {
    return (<div className={cn("mb-3 grid gap-3 text-center text-sm", items.length >= 4 ? "grid-cols-2 sm:grid-cols-4" : items.length === 3 ? "grid-cols-3" : "grid-cols-2", className)}>
      {items.map((item) => (<div key={item.label} className="rounded-lg border border-border bg-muted/20 px-2 py-2">
          <p className="text-xs uppercase tracking-wide text-muted">{item.label}</p>
          <p className="text-lg font-semibold tabular-nums text-foreground">{item.value}</p>
        </div>))}
    </div>);
}

export function ChartCaption({ children, className }: {
    children: React.ReactNode;
    className?: string;
}) {
    return <p className={cn("mt-2 text-center text-xs text-muted", className)}>{children}</p>;
}
