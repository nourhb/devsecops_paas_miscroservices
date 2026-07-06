// Layout wrapper for (dashboard) pages
import { AppShell, AuthGuard } from "@/components/layout/app-shell";
export default function DashboardLayout({ children }: {
    children: React.ReactNode;
}) {
    return (<AuthGuard>
      <AppShell>{children}</AppShell>
    </AuthGuard>);
}
