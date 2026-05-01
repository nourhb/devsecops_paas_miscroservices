"use client";
import axios from "axios";
import { FormEvent, useState } from "react";
import Link from "next/link";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { authApi } from "@/lib/api";
export default function ForgotPasswordPage() {
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const [success, setSuccess] = useState<string | null>(null);
    const onSubmit = async (event: FormEvent<HTMLFormElement>) => {
        event.preventDefault();
        setLoading(true);
        setError(null);
        setSuccess(null);
        const formData = new FormData(event.currentTarget);
        const email = String(formData.get("email") || "").trim();
        try {
            const response = await authApi.forgotPassword(email);
            setSuccess(response.mailDelivery === "console"
                ? `${response.message} Mailer is not configured, so the reset link was written to the server console.`
                : response.message);
        }
        catch (err) {
            let msg = "Unable to send password reset email.";
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
          <CardTitle>Forgot password</CardTitle>
          <CardDescription>Enter your email and we will send you a reset link.</CardDescription>
        </CardHeader>
        <CardContent>
          <form className="space-y-4" onSubmit={onSubmit}>
            <div className="space-y-2">
              <Label htmlFor="email">Email</Label>
              <Input id="email" name="email" type="email" required placeholder="dev@example.com"/>
            </div>
            {success ? <p className="text-sm text-success">{success}</p> : null}
            {error ? <p className="text-sm text-danger">{error}</p> : null}
            <Button type="submit" className="w-full" disabled={loading}>
              {loading ? "Sending reset link..." : "Send reset link"}
            </Button>
          </form>
          <p className="mt-4 text-center text-sm text-muted">
            Back to <Link href="/login" className="text-primary">login</Link>
          </p>
        </CardContent>
      </Card>
    </div>;
}
