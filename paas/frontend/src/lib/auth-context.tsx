"use client";
import { createContext, ReactNode, useCallback, useContext, useEffect, useMemo, useState } from "react";
import { authApi } from "@/lib/api";
import { authStorage } from "@/lib/auth-storage";
import type { AuthStatusResponse, LoginRequest, RegisterRequest, UpdateProfileRequest, UserProfile } from "@/types";
interface AuthContextValue {
    user: UserProfile | null;
    loading: boolean;
    isAuthenticated: boolean;
    login: (payload: LoginRequest) => Promise<void>;
    register: (payload: RegisterRequest) => Promise<AuthStatusResponse>;
    logout: () => Promise<void>;
    updateProfile: (payload: UpdateProfileRequest) => Promise<{
        message: string;
    }>;
    refreshUser: () => Promise<void>;
}
const AuthContext = createContext<AuthContextValue | null>(null);
export function AuthProvider({ children }: {
    children: ReactNode;
}) {
    const [user, setUser] = useState<UserProfile | null>(null);
    const [loading, setLoading] = useState(true);
    useEffect(() => {
        const storedUser = authStorage.getUser();
        if (storedUser) {
            setUser(storedUser);
        }
        else {
            authStorage.clear();
        }
        let cancelled = false;
        authApi.session()
            .then((session) => {
            if (cancelled) {
                return;
            }
            if (session.authenticated && session.user) {
                authStorage.setUser(session.user);
                setUser(session.user);
                return;
            }
            authStorage.clear();
            setUser(null);
        })
            .catch(() => {
            if (cancelled) {
                return;
            }
            authStorage.clear();
            setUser(null);
        })
            .finally(() => {
            if (!cancelled) {
                setLoading(false);
            }
        });
        return () => {
            cancelled = true;
        };
    }, []);
    const login = useCallback(async (payload: LoginRequest) => {
        const data = await authApi.login(payload);
        authStorage.setUser(data.user);
        setUser(data.user);
    }, []);
    const register = useCallback(async (payload: RegisterRequest) => {
        const data = await authApi.register(payload);
        return data;
    }, []);
    const logout = useCallback(async () => {
        try {
            await authApi.logout();
        }
        catch {
        }
        authStorage.clear();
        setUser(null);
    }, []);
    const updateProfile = useCallback(async (payload: UpdateProfileRequest) => {
        const data = await authApi.updateProfile(payload);
        authStorage.setUser(data.user);
        setUser(data.user);
        return { message: data.message };
    }, []);
    const refreshUser = useCallback(async () => {
        const session = await authApi.session();
        if (session.authenticated && session.user) {
            authStorage.setUser(session.user);
            setUser(session.user);
        }
    }, []);
    const value = useMemo(() => ({
        user,
        loading,
        isAuthenticated: Boolean(user),
        login,
        register,
        logout,
        updateProfile,
        refreshUser
    }), [user, loading, login, register, logout, updateProfile, refreshUser]);
    return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}
export function useAuth() {
    const context = useContext(AuthContext);
    if (!context) {
        throw new Error("useAuth must be used within AuthProvider");
    }
    return context;
}
