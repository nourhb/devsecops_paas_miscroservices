"use client";
export const dynamic = "force-dynamic";
import axios from "axios";
import { useEffect, useState } from "react";
import Link from "next/link";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { authApi } from "@/lib/api";
export default function VerifyEmailPage() {
    const [token, setToken] = useState("");
    const [initialized, setInitialized] = useState(false);
    const [loading, setLoading] = useState(true);
    const [message, setMessage] = useState("Verifying your account...");
    const [error, setError] = useState<string | null>(null);
    useEffect(() => {
        if (typeof window !== "undefined") {
            setToken(new URLSearchParams(window.location.search).get("token") || "");
        }
        setInitialized(true);
    }, []);
    useEffect(() => {
        if (!initialized) {
            return;
        }
        let active = true;
        async function verify() {
            if (!token) {
                if (!active) {
                    return;
                }
                setLoading(false);
                setError("Verification token is missing.");
                return;
            }
            try {
                const response = await authApi.verifyEmail(token);
                if (!active) {
                    return;
                }
                setMessage(response.message);
                setError(null);
            }
            catch (err) {
                if (!active) {
                    return;
                }
                let msg = "Unable to verify this email link.";
                if (axios.isAxiosError(err) && typeof err.response?.data?.message === "string") {
                    msg = err.response.data.message;
                }
                setError(msg);
            }
            finally {
                if (active) {
                    setLoading(false);
                }
            }
        }
        void verify();
        return () => {
            active = false;
        };
    }, [initialized, token]);
    return <div className="flex min-h-screen items-center justify-center px-4">
      <Card className="w-full max-w-md backdrop-blur">
        <CardHeader>
          <CardTitle>Verify email</CardTitle>
          <CardDescription>We are confirming your registered account.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          {loading ? <p className="text-sm text-muted">{message}</p> : null}
          {!loading && !error ? <p className="text-sm text-success">{message}</p> : null}
          {!loading && error ? <p className="text-sm text-danger">{error}</p> : null}
          <Button asChild className="w-full">
            <Link href="/login">Go to login</Link>
          </Button>
        </CardContent>
      </Card>
    </div>;
}
