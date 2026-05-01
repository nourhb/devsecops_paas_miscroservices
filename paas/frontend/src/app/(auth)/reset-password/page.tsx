"use client";
export const dynamic = "force-dynamic";
import axios from "axios";
import { FormEvent, useEffect, useState } from "react";
import Link from "next/link";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { authApi } from "@/lib/api";
export default function ResetPasswordPage() {
    const [token, setToken] = useState("");
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const [success, setSuccess] = useState<string | null>(null);
    useEffect(() => {
        if (typeof window !== "undefined") {
            setToken(new URLSearchParams(window.location.search).get("token") || "");
        }
    }, []);
    const onSubmit = async (event: FormEvent<HTMLFormElement>) => {
        event.preventDefault();
        const form = event.currentTarget;
        setLoading(true);
        setError(null);
        setSuccess(null);
        const formData = new FormData(form);
        const password = String(formData.get("password") || "");
        const confirmPassword = String(formData.get("confirmPassword") || "");
        if (!token) {
            setError("Reset token is missing.");
            setLoading(false);
            return;
        }
        if (password !== confirmPassword) {
            setError("Passwords do not match.");
            setLoading(false);
            return;
        }
        try {
            const response = await authApi.resetPassword(token, password);
            setSuccess(response.message);
            form.reset();
        }
        catch (err) {
            let msg = "Unable to reset password.";
            if (axios.isAxiosError(err) && typeof err.response?.data?.message === "string") {
                msg = err.response.data.message;
            }
            setError(msg);
        }
        finally {
            setLoading(false);
        }
    };
    return <div className="flex min-h-screen items-center justify-center px-4">
      <Card className="w-full max-w-md backdrop-blur">
        <CardHeader>
          <CardTitle>Reset password</CardTitle>
          <CardDescription>Create a new password for your account.</CardDescription>
        </CardHeader>
        <CardContent>
          <form className="space-y-4" onSubmit={onSubmit}>
            <div className="space-y-2">
              <Label htmlFor="password">New password</Label>
              <Input id="password" name="password" type="password" required minLength={8}/>
            </div>
            <div className="space-y-2">
              <Label htmlFor="confirmPassword">Confirm password</Label>
              <Input id="confirmPassword" name="confirmPassword" type="password" required minLength={8}/>
            </div>
            {success ? <p className="text-sm text-success">{success}</p> : null}
            {error ? <p className="text-sm text-danger">{error}</p> : null}
            <Button type="submit" className="w-full" disabled={loading}>
              {loading ? "Updating password..." : "Update password"}
            </Button>
          </form>
          <p className="mt-4 text-center text-sm text-muted">
            Back to <Link href="/login" className="text-primary">login</Link>
          </p>
        </CardContent>
      </Card>
    </div>;
}
