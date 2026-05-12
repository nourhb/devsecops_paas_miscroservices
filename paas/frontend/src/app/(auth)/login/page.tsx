import { keycloakSsoConfigured } from "@/server/auth/keycloak-sso";
import { LoginForm } from "./login-form";
export const dynamic = "force-dynamic";
type Search = Record<string, string | string[] | undefined>;
function firstParam(v: string | string[] | undefined): string | undefined {
    if (typeof v === "string") {
        return v;
    }
    if (Array.isArray(v) && typeof v[0] === "string") {
        return v[0];
    }
    return undefined;
}
export default function LoginPage({ searchParams }: {
    searchParams: Search;
}) {
    const kcError = firstParam(searchParams.kc_error);
    return <LoginForm keycloakEnabled={keycloakSsoConfigured()} keycloakError={kcError}/>;
}
