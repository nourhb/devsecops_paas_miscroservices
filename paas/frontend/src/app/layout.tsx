import type { Metadata } from "next";
import "@fontsource/space-grotesk/300.css";
import "@fontsource/space-grotesk/400.css";
import "@fontsource/space-grotesk/500.css";
import "@fontsource/space-grotesk/600.css";
import "@fontsource/space-grotesk/700.css";
import "@/app/globals.css";
import { QueryProvider } from "@/lib/query-provider";
import { AuthProvider } from "@/lib/auth-context";
import { ThemeProvider } from "@/components/theme-provider";
import { Toaster } from "sonner";
const appTitle = process.env.NEXT_PUBLIC_APP_NAME?.trim() || "DevSecOps PaaS";
export const metadata: Metadata = {
    title: appTitle,
    description: "Full-stack DevOps control plane: CI/CD, security, containers, and observability"
};
export default function RootLayout({ children }: {
    children: React.ReactNode;
}) {
    return (<html lang="en" dir="ltr" suppressHydrationWarning>
      <body className="font-sans antialiased">
        <ThemeProvider attribute="class" defaultTheme="dark" enableSystem disableTransitionOnChange>
          <QueryProvider>
            <AuthProvider>{children}</AuthProvider>
          </QueryProvider>
          <Toaster richColors closeButton position="top-right"/>
        </ThemeProvider>
      </body>
    </html>);
}
