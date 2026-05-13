"use client";
import { Moon, Sun } from "lucide-react";
import { useTheme } from "next-themes";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { hints } from "@/lib/app-hints";
export function ThemeToggle() {
    const { theme, setTheme, resolvedTheme } = useTheme();
    const [mounted, setMounted] = useState(false);
    useEffect(() => {
        setMounted(true);
    }, []);
    if (!mounted) {
        return (<Button variant="outline" size="sm" className="h-9 w-9 p-0" aria-label="Toggle theme" disabled>
        <Sun className="h-4 w-4"/>
      </Button>);
    }
    const isDark = resolvedTheme === "dark" || theme === "dark";
    return (<Tooltip delayDuration={280}>
      <TooltipTrigger asChild>
        <Button variant="outline" size="sm" className="h-9 w-9 p-0" type="button" aria-label={isDark ? "Switch to light mode" : "Switch to dark mode"} onClick={() => setTheme(isDark ? "light" : "dark")}>
          {isDark ? <Sun className="h-4 w-4"/> : <Moon className="h-4 w-4"/>}
        </Button>
      </TooltipTrigger>
      <TooltipContent className="max-w-xs">{hints.topNav.theme}</TooltipContent>
    </Tooltip>);
}
