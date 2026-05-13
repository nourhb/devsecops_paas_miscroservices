"use client";
import type { ReactNode } from "react";
import { CircleHelp } from "lucide-react";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";
type HintSide = "top" | "right" | "bottom" | "left";
export function Hint({ children, className, side = "top", delayDuration = 280 }: {
    children: ReactNode;
    className?: string;
    side?: HintSide;
    /** Ms before open — keeps dense UIs from flickering. */
    delayDuration?: number;
}) {
    return (<Tooltip delayDuration={delayDuration}>
      <TooltipTrigger asChild>
        <button type="button" className={cn("inline-flex shrink-0 rounded-full text-muted-foreground outline-none transition-colors hover:text-foreground focus-visible:ring-2 focus-visible:ring-primary/40 focus-visible:ring-offset-1 focus-visible:ring-offset-background", className)} aria-label="Quick explanation">
          <CircleHelp className="h-3.5 w-3.5" strokeWidth={2} aria-hidden/>
        </button>
      </TooltipTrigger>
      <TooltipContent side={side} className="max-w-[min(20rem,calc(100vw-2rem))] font-normal">
        {children}
      </TooltipContent>
    </Tooltip>);
}
