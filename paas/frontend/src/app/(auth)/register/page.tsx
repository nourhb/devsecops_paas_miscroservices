"use client";
import axios from "axios";
import { FormEvent, useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useAuth } from "@/hooks/use-auth";
export default function RegisterPage() {
    const { register, login } = useAuth();
    const router = useRouter();
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const [success, setSuccess] = useState<string | null>(null);
    const submitSeq = useRef(0);
    const onSubmit = async (event: FormEvent<HTMLFormElement>) => {
        event.preventDefault();
        if (loading) {
            return;
        }
        const seq = ++submitSeq.current;
        setLoading(true);
        setError(null);
        setSuccess(null);
        const formData = new FormData(event.currentTarget);
        try {
            const response = await register({
                fullName: String(formData.get("fullName") || "").trim(),
                email: String(formData.get("email") || "").trim(),
                password: String(formData.get("password") || ""),
                role: "DEVELOPER"
            });
            if (seq !== submitSeq.current) {
                return;
            }
            const email = String(formData.get("email") || "").trim();
            const password = String(formData.get("password") || "");
            await login({ email, password });
            if (seq !== submitSeq.current) {
                return;
            }
            setSuccess(response.message || "Account created. Redirecting to dashboard...");
            setError(null);
            router.replace("/dashboard");
        }
        catch (err) {
            if (seq !== submitSeq.current) {
                return;
            }
            let msg = "Unable to register with provided details.";
            if (axios.isAxiosError(err) && typeof err.response?.data?.message === "string") {
                msg = err.response.data.message;
            }
            setError(msg);
            setSuccess(null);
        }
        finally {
            if (seq === submitSeq.current) {
                setLoading(false);
            }
        }
    };
    return (<div className="flex min-h-screen items-center justify-center px-4">
      <Card className="w-full max-w-md backdrop-blur">
        <CardHeader>
          <CardTitle>Create your account</CardTitle>
          <CardDescription>Access secure CI/CD workflows from one platform.</CardDescription>
        </CardHeader>
        <CardContent>
          <form className="space-y-4" onSubmit={onSubmit}>
            <div className="space-y-2">
              <Label htmlFor="fullName">Full Name</Label>
              <Input id="fullName" name="fullName" required/>
            </div>
            <div className="space-y-2">
              <Label htmlFor="email">Email</Label>
              <Input id="email" name="email" type="email" required/>
            </div>
            <div className="space-y-2">
              <Label htmlFor="password">Password</Label>
              <Input id="password" name="password" type="password" required minLength={8} autoComplete="new-password"/>
              <p className="text-xs text-muted">At least 8 characters.</p>
            </div>
            {success ? <p className="text-sm text-success">{success}</p> : null}
            {error ? <p className="text-sm text-danger">{error}</p> : null}
            <Button type="submit" className="w-full" disabled={loading}>
              {loading ? "Creating account..." : "Register"}
            </Button>
          </form>
          <p className="mt-4 text-center text-sm text-muted">
            Already have an account? <Link href="/login" className="text-primary">Login</Link>
          </p>
        </CardContent>
      </Card>
    </div>);
}
