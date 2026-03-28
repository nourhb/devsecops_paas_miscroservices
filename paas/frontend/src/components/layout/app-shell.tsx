import { SideNav } from "@/components/layout/side-nav";
import { TopNav } from "@/components/layout/top-nav";

export function AppShell({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-screen bg-background text-foreground lg:flex">
      <SideNav />
      <div className="flex-1">
        <TopNav />
        <main className="p-4 lg:p-6">{children}</main>
      </div>
    </div>
  );
}
