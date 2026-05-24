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
    const postRegisterEmail = firstParam(searchParams.pendingVerification) === "1" ? firstParam(searchParams.email)?.trim() : undefined;
    const mailConsole = firstParam(searchParams.mailConsole) === "1";
    return (<LoginForm keycloakEnabled={keycloakSsoConfigured()} keycloakError={kcError} postRegisterEmail={postRegisterEmail} postRegisterMailConsole={mailConsole}/>);
}
