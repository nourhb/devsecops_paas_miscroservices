import type { UserProfile } from "@/types";
const USER_KEY = "paas_user";
export const authStorage = {
    getToken(): string | null {
        return null;
    },
    setUser(user: UserProfile) {
        if (typeof window === "undefined")
            return;
        window.localStorage.setItem(USER_KEY, JSON.stringify(user));
    },
    getUser(): UserProfile | null {
        if (typeof window === "undefined")
            return null;
        const raw = window.localStorage.getItem(USER_KEY);
        if (!raw)
            return null;
        try {
            return JSON.parse(raw) as UserProfile;
        }
        catch {
            return null;
        }
    },
    hasUser(): boolean {
        return Boolean(this.getUser());
    },
    clear() {
        if (typeof window === "undefined")
            return;
        window.localStorage.removeItem(USER_KEY);
    }
};
