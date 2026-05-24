import nodemailer from "nodemailer";
import { env } from "@/server/config/env";
type MailPayload = {
    to: string;
    cc?: string;
    subject: string;
    html: string;
    text: string;
};
let transporterPromise: Promise<nodemailer.Transporter> | null = null;
function smtpHost() {
    return (env.SMTP_HOST || "").trim();
}
function smtpUser() {
    return (env.SMTP_USER || "").trim();
}
function hasSmtpConfig() {
    return Boolean(smtpHost() && env.SMTP_PORT && smtpUser() && env.SMTP_PASS);
}
function resolveSmtpPassword() {
    const password = (env.SMTP_PASS || "").trim();
    if (smtpHost().toLowerCase() === "smtp.gmail.com") {
        return password.replace(/\s+/g, "");
    }
    return password;
}
async function getTransporter() {
    if (!transporterPromise) {
        const port = env.SMTP_PORT;
        const secure = env.SMTP_SECURE === "true";
        transporterPromise = Promise.resolve(nodemailer.createTransport({
            host: smtpHost(),
            port,
            secure,
            requireTLS: !secure && port === 587,
            auth: {
                user: smtpUser(),
                pass: resolveSmtpPassword()
            }
        }));
    }
    return transporterPromise;
}
export function getAppBaseUrl() {
    return (env.APP_BASE_URL || "http://localhost:3000").replace(/\/+$/, "");
}
export async function sendAuthMail(payload: MailPayload) {
    const from = env.MAIL_FROM || env.SMTP_USER || "no-reply@localhost";
    if (!hasSmtpConfig()) {
        console.info("[auth-mail]", {
            to: payload.to,
            cc: payload.cc,
            subject: payload.subject,
            text: payload.text
        });
        return {
            delivered: false,
            mode: "console" as const
        };
    }
    try {
        const transporter = await getTransporter();
        await transporter.sendMail({
            from,
            to: payload.to,
            ...(payload.cc ? { cc: payload.cc } : {}),
            subject: payload.subject,
            text: payload.text,
            html: payload.html
        });
        return {
            delivered: true,
            mode: "smtp" as const
        };
    }
    catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        console.error("[auth-mail] SMTP send failed", { to: payload.to, host: smtpHost(), message });
        throw err;
    }
}
