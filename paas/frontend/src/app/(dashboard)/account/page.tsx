"use client";
import axios from "axios";
import { FormEvent, useEffect, useState } from "react";
import { UserRound } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useAuth } from "@/hooks/use-auth";
export default function AccountSettingsPage() {
    const { user, refreshUser, updateProfile } = useAuth();
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const [success, setSuccess] = useState<string | null>(null);
    const [fullName, setFullName] = useState("");
    const [email, setEmail] = useState("");
    const [currentPassword, setCurrentPassword] = useState("");
    const [newPassword, setNewPassword] = useState("");
    const [confirmPassword, setConfirmPassword] = useState("");
    useEffect(() => {
        if (user) {
            setFullName(user.fullName || "");
            setEmail(user.email || "");
        }
    }, [user]);
    const isKeycloak = user?.accountKind === "keycloak";
    const handleSave = async () => {
        setError(null);
        setSuccess(null);
        if (newPassword && newPassword !== confirmPassword) {
            setError("New password and confirmation do not match.");
            return;
        }
        const payload: {
            fullName?: string;
            email?: string;
            currentPassword?: string;
            newPassword?: string;
        } = {};
        const nameTrim = fullName.trim();
        if (nameTrim && nameTrim !== (user?.fullName || "")) {
            payload.fullName = nameTrim;
        }
        if (!isKeycloak) {
            const emailTrim = email.trim().toLowerCase();
            if (emailTrim && emailTrim !== (user?.email || "").toLowerCase()) {
                payload.email = emailTrim;
            }
        }
        if (!isKeycloak && newPassword) {
            if (!currentPassword) {
                setError("Enter your current password to set a new one.");
                return;
            }
            payload.newPassword = newPassword;
            payload.currentPassword = currentPassword;
        }
        if (!payload.fullName && !payload.email && !payload.newPassword) {
            setError("Change at least one field before saving.");
            return;
        }
        setLoading(true);
        try {
            const data = await updateProfile(payload);
            setSuccess(data.message);
            setCurrentPassword("");
            setNewPassword("");
            setConfirmPassword("");
            await refreshUser();
        }
        catch (err) {
            let msg = "Could not update profile.";
            if (axios.isAxiosError(err) && typeof err.response?.data?.message === "string") {
                msg = err.response.data.message;
            }
            setError(msg);
        }
        finally {
            setLoading(false);
        }
    };
    const onSubmitForm = (event: FormEvent<HTMLFormElement>) => {
        event.preventDefault();
        void handleSave();
    };
    return (<div className="mx-auto max-w-xl space-y-6">
      <div>
        <p className="text-xs uppercase tracking-wide text-muted">Account</p>
        <h1 className="mt-1 flex flex-wrap items-center gap-2 text-2xl font-semibold tracking-tight">
          <UserRound className="h-7 w-7 text-primary"/>
          Profile & security
        </h1>
      </div>
      <Card className="rounded-2xl border-border/70">
        <CardHeader>
          <CardTitle className="text-lg">Your details</CardTitle>
          <CardDescription>
            Signed in as <span className="font-medium text-foreground">{user?.role ?? "—"}</span>
            {user?.accountKind
            ? ` · ${user.accountKind === "keycloak" ? "Keycloak" : "Local password"}`
            : ""}
          </CardDescription>
        </CardHeader>
        <CardContent>
          <form className="space-y-5" onSubmit={onSubmitForm}>
            <div className="space-y-2">
              <Label htmlFor="fullName">Full name</Label>
              <Input id="fullName" value={fullName} onChange={(e) => setFullName(e.target.value)} autoComplete="name"/>
            </div>
            <div className="space-y-2">
              <Label htmlFor="email">Email</Label>
              <Input id="email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} disabled={isKeycloak} autoComplete="email" className={isKeycloak ? "opacity-80" : ""}/>
            </div>
            {!isKeycloak ? (<div className="space-y-4 rounded-xl border border-border/60 bg-muted/10 p-4">
                <p className="text-sm font-medium text-foreground">Change password</p>
                <div className="space-y-2">
                  <Label htmlFor="currentPassword">Current password</Label>
                  <Input id="currentPassword" type="password" value={currentPassword} onChange={(e) => setCurrentPassword(e.target.value)} autoComplete="current-password"/>
                </div>
                <div className="space-y-2">
                  <Label htmlFor="newPassword">New password</Label>
                  <Input id="newPassword" type="password" value={newPassword} onChange={(e) => setNewPassword(e.target.value)} autoComplete="new-password" minLength={8}/>
                </div>
                <div className="space-y-2">
                  <Label htmlFor="confirmPassword">Confirm new password</Label>
                  <Input id="confirmPassword" type="password" value={confirmPassword} onChange={(e) => setConfirmPassword(e.target.value)} autoComplete="new-password" minLength={8}/>
                </div>
              </div>) : null}
            {success ? <p className="text-sm text-success">{success}</p> : null}
            {error ? <p className="text-sm text-danger">{error}</p> : null}
            <Button type="submit" disabled={loading}>
              {loading ? "Saving…" : "Save changes"}
            </Button>
          </form>
        </CardContent>
      </Card>
    </div>);
}
