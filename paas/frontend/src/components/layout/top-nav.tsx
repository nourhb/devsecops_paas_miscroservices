"use client";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { LayoutGrid } from "lucide-react";
import { Button } from "@/components/ui/button";
import { ThemeToggle } from "@/components/layout/theme-toggle";
import { useAuth } from "@/hooks/use-auth";
export function TopNav() {
    const { user, logout } = useAuth();
    const router = useRouter();
    const handleLogout = async () => {
        await logout();
        router.replace("/login");
    };
    return (<header className="sticky top-0 z-40 flex h-16 shrink-0 items-center justify-between border-b border-border bg-card/95 px-4 shadow-sm backdrop-blur-md supports-[backdrop-filter]:bg-card/80 lg:px-6">
      <div className="min-w-0 text-left">
        <p className="text-sm text-muted">Secure Delivery Platform</p>
        <p className="text-sm font-semibold">
          {user?.fullName} ({user?.role})
        </p>
      </div>
      <div className="flex items-center gap-2">
        <Button variant="outline" size="sm" className="lg:hidden" asChild>
          <Link href="/integrations">
            <LayoutGrid className="h-4 w-4"/>
          </Link>
        </Button>
        <ThemeToggle />
        <Button variant="outline" type="button" onClick={handleLogout}>
          Logout
        </Button>
      </div>
    </header>);
}
