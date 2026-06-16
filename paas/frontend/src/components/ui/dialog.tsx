"use client";
import * as React from "react";
import { createPortal } from "react-dom";
import { X } from "lucide-react";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";

interface DialogProps {
    open: boolean;
    onOpenChange: (open: boolean) => void;
    children: React.ReactNode;
    className?: string;
}

export function Dialog({ open, onOpenChange, children, className }: DialogProps) {
  const [mounted, setMounted] = React.useState(false);
  React.useEffect(() => {
    setMounted(true);
  }, []);
  React.useEffect(() => {
    if (!open) {
      return;
    }
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        onOpenChange(false);
      }
    };
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    window.addEventListener("keydown", onKey);
    return () => {
      document.body.style.overflow = prev;
      window.removeEventListener("keydown", onKey);
    };
  }, [open, onOpenChange]);
  if (!open || !mounted) {
    return null;
  }
  return createPortal(<div className="fixed inset-0 z-[200] flex items-center justify-center p-4" role="presentation">
      <button type="button" className="absolute inset-0 bg-background/80 backdrop-blur-sm" aria-label="Close dialog" onClick={() => onOpenChange(false)}/>
      <div role="dialog" aria-modal="true" dir="ltr" className={cn("relative z-10 flex max-h-[min(90vh,720px)] w-full max-w-lg flex-col overflow-hidden rounded-2xl border border-border bg-card text-left shadow-2xl sm:max-w-2xl", className)}>
        {children}
      </div>
    </div>, document.body);
}

export function DialogHeader({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn("flex flex-col gap-1 border-b border-border/60 px-5 py-4 text-left sm:px-6", className)} {...props}/>;
}

export function DialogTitle({ className, ...props }: React.HTMLAttributes<HTMLHeadingElement>) {
  return <h2 className={cn("text-left text-lg font-semibold leading-tight tracking-tight text-foreground", className)} {...props}/>;
}

export function DialogDescription({ className, ...props }: React.HTMLAttributes<HTMLParagraphElement>) {
  return <p className={cn("text-left text-sm text-muted", className)} {...props}/>;
}

export function DialogBody({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn("flex-1 overflow-y-auto px-5 py-4 text-left sm:px-6", className)} {...props}/>;
}

export function DialogFooter({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn("flex flex-col-reverse gap-2 border-t border-border/60 px-5 py-4 sm:flex-row sm:justify-end sm:px-6", className)} {...props}/>;
}

interface DialogCloseProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
    onClose: () => void;
}

export function DialogClose({ onClose, className, ...props }: DialogCloseProps) {
  return (<Button type="button" variant="ghost" size="sm" className={cn("absolute right-3 top-3 h-8 w-8 p-0", className)} onClick={onClose} aria-label="Close" {...props}>
      <X className="h-4 w-4"/>
    </Button>);
}
