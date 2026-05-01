import nodemailer from "nodemailer";
import { env } from "@/server/config/env";
type MailPayload = {
    to: string;
    subject: string;
    html: string;
    text: string;
};
let transporterPromise: Promise<nodemailer.Transporter> | null = null;
function hasSmtpConfig() {
    return Boolean(env.SMTP_HOST && env.SMTP_PORT && env.SMTP_USER && env.SMTP_PASS);
}
function resolveSmtpPassword() {
    const password = env.SMTP_PASS || "";
    if (env.SMTP_HOST.toLowerCase() === "smtp.gmail.com") {
        return password.replace(/\s+/g, "");
    }
    return password;
}
async function getTransporter() {
    if (!transporterPromise) {
        transporterPromise = Promise.resolve(nodemailer.createTransport({
            host: env.SMTP_HOST,
            port: env.SMTP_PORT,
            secure: env.SMTP_SECURE === "true",
            auth: {
                user: env.SMTP_USER,
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
            subject: payload.subject,
            text: payload.text
        });
        return {
            delivered: false,
            mode: "console" as const
        };
    }
    const transporter = await getTransporter();
    await transporter.sendMail({
        from,
        to: payload.to,
        subject: payload.subject,
        text: payload.text,
        html: payload.html
    });
    return {
        delivered: true,
        mode: "smtp" as const
    };
}
