"use client";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { LayoutGrid } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/hooks/use-auth";
import { ThemeToggle } from "@/components/layout/theme-toggle";
export function TopNav() {
    const { user, logout } = useAuth();
    const router = useRouter();
    const handleLogout = async () => {
        await logout();
        router.replace("/login");
    };
    return (<header className="flex h-16 items-center justify-between border-b border-border bg-card px-4 lg:px-6">
      <div>
        <p className="text-sm text-muted">Secure Delivery Platform</p>
        <p className="text-sm font-semibold">
          {user?.fullName} ({user?.role})
        </p>
      </div>
      <div className="flex items-center gap-2">
        <Button variant="outline" size="sm" className="lg:hidden" asChild>
          <Link href="/integrations" title="Platform hub">
            <LayoutGrid className="h-4 w-4"/>
          </Link>
        </Button>
        <ThemeToggle />
        <Button variant="outline" onClick={handleLogout}>
          Logout
        </Button>
      </div>
    </header>);
}
