import type { LucideIcon } from "lucide-react";
import type { ReactNode } from "react";
import { Card } from "@/components/ui/card";
import { Hint } from "@/components/hint";
import { cn } from "@/lib/utils";
interface OverviewStatCardProps {
    title: string;
    value: string | number;
    icon: LucideIcon;
    className?: string;
    hint?: ReactNode;
}
export function OverviewStatCard({ title, value, icon: Icon, className, hint }: OverviewStatCardProps) {
    return (<Card className={cn("overflow-hidden rounded-xl border-border/70 bg-card shadow-sm transition-shadow duration-200 hover:shadow-md", className)}>
      <div className="flex items-start justify-between gap-4 p-5">
        <div className="min-w-0 space-y-1">
          <div className="flex items-center gap-1">
            <p className="text-[11px] font-medium uppercase tracking-widest text-muted">{title}</p>
            {hint ? <Hint side="top">{hint}</Hint> : null}
          </div>
          <p className="text-3xl font-semibold tracking-tight text-foreground tabular-nums">{value}</p>
        </div>
        <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl border border-border/50 bg-muted/40 text-muted" aria-hidden>
          <Icon className="h-5 w-5" strokeWidth={1.5}/>
        </div>
      </div>
    </Card>);
}
