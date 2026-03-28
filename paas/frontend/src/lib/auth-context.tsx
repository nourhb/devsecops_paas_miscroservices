"use client";

import { createContext, ReactNode, useContext, useEffect, useMemo, useState } from "react";
import { authApi } from "@/lib/api";
import { authStorage } from "@/lib/auth-storage";
import type { LoginRequest, RegisterRequest, UserProfile } from "@/types";

interface AuthContextValue {
  user: UserProfile | null;
  loading: boolean;
  isAuthenticated: boolean;
  login: (payload: LoginRequest) => Promise<void>;
  register: (payload: RegisterRequest) => Promise<void>;
  logout: () => void;
}

const AuthContext = createContext<AuthContextValue | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<UserProfile | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const token = authStorage.getToken();
    const storedUser = authStorage.getUser();

    if (token && storedUser && !authStorage.isTokenExpired(token)) {
      setUser(storedUser);
    } else {
      authStorage.clear();
    }
    setLoading(false);
  }, []);

  const login = async (payload: LoginRequest) => {
    const data = await authApi.login(payload);
    authStorage.setToken(data.token);
    authStorage.setUser(data.user);
    setUser(data.user);
  };

  const register = async (payload: RegisterRequest) => {
    const data = await authApi.register(payload);
    authStorage.setToken(data.token);
    authStorage.setUser(data.user);
    setUser(data.user);
  };

  const logout = () => {
    authStorage.clear();
    setUser(null);
  };

  const value = useMemo(
    () => ({
      user,
      loading,
      isAuthenticated: Boolean(user),
      login,
      register,
      logout
    }),
    [user, loading]
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (!context) {
    throw new Error("useAuth must be used within AuthProvider");
  }
  return context;
}
