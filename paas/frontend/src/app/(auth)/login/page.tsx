"use client";
export const dynamic = "force-dynamic";
import { FormEvent, useEffect, useState } from "react";
import axios from "axios";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useAuth } from "@/hooks/use-auth";
import { authApi } from "@/lib/api";
export default function LoginPage() {
    const router = useRouter();
    const getNextParam = () => (typeof window !== "undefined" ? new URLSearchParams(window.location.search).get("next") : null);
    const { login } = useAuth();
    const [destination, setDestination] = useState("/dashboard");
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const [unverifiedEmail, setUnverifiedEmail] = useState("");
    const [notice, setNotice] = useState<string | null>(null);
    useEffect(() => {
        setDestination(getNextParam() || "/dashboard");
    }, []);
    useEffect(() => {
        router.prefetch(destination);
    }, [destination, router]);
    const onSubmit = async (event: FormEvent<HTMLFormElement>) => {
        event.preventDefault();
        setLoading(true);
        setError(null);
        setNotice(null);
        setUnverifiedEmail("");
        const formData = new FormData(event.currentTarget);
        const email = String(formData.get("email") || "");
        const password = String(formData.get("password") || "");
        try {
            await login({ email, password });
            router.replace(destination);
            window.setTimeout(() => {
                if (typeof window !== "undefined" && window.location.pathname !== destination) {
                    window.location.assign(destination);
                }
            }, 250);
        }
        catch (err) {
            if (axios.isAxiosError(err)) {
                const data = err.response?.data as {
                    code?: string;
                    email?: string;
                    message?: string;
                } | undefined;
                if (data?.code === "EMAIL_NOT_VERIFIED") {
                    setUnverifiedEmail(typeof data.email === "string" ? data.email : email);
                    setError(typeof data.message === "string"
                        ? data.message
                        : "Please verify your email before signing in.");
                }
                else if (typeof data?.message === "string" && data.message.trim()) {
                    setError(data.message);
                }
                else {
                    setError("Invalid credentials. Please try again.");
                }
            }
            else {
                setError("Invalid credentials. Please try again.");
            }
        }
        finally {
            setLoading(false);
        }
    };
    const handleResendVerification = async () => {
        if (!unverifiedEmail) {
            return;
        }
        setNotice(null);
        setError(null);
        try {
            const response = await authApi.resendVerification(unverifiedEmail);
            setNotice(response.mailDelivery === "console"
                ? `${response.message} Mailer is not configured, so the verification link was written to the server console.`
                : response.message);
        }
        catch {
            setError("Unable to resend verification email right now.");
        }
    };
    return (<div className="flex min-h-screen items-center justify-center px-4">
      <Card className="w-full max-w-md backdrop-blur">
        <CardHeader>
          <CardTitle>Sign in to DevSecOps PaaS</CardTitle>
          <CardDescription>Run secure builds and deployments without direct Jenkins access.</CardDescription>
        </CardHeader>
        <CardContent>
          <form className="space-y-4" onSubmit={onSubmit}>
            <div className="space-y-2">
              <Label htmlFor="email">Email</Label>
              <Input id="email" name="email" type="email" required placeholder="dev@example.com"/>
            </div>
            <div className="space-y-2">
              <Label htmlFor="password">Password</Label>
              <Input id="password" name="password" type="password" required placeholder="********"/>
            </div>
            {notice ? <p className="text-sm text-success">{notice}</p> : null}
            {error ? <p className="text-sm text-danger">{error}</p> : null}
            <Button type="submit" className="w-full" disabled={loading}>
              {loading ? "Signing in..." : "Login"}
            </Button>
          </form>
          {unverifiedEmail ? <div className="mt-4 rounded-md border border-border bg-muted/30 p-3 text-sm">
              <p className="text-muted">Didn&apos;t get the verification email?</p>
              <Button type="button" variant="outline" className="mt-3 w-full" onClick={() => void handleResendVerification()}>
                Resend verification email
              </Button>
            </div> : null}
          <p className="mt-4 text-center text-sm text-muted">
            <Link href="/forgot-password" className="text-primary">Forgot password?</Link>
          </p>
          <p className="mt-2 text-center text-sm text-muted">
            Need an account? <Link href="/register" className="text-primary">Register</Link>
          </p>
        </CardContent>
      </Card>
    </div>);
}
