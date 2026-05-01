import type { Config } from "tailwindcss";
const config: Config = {
    darkMode: ["class"],
    content: [
        "./src/pages/**/*.{js,ts,jsx,tsx,mdx}",
        "./src/components/**/*.{js,ts,jsx,tsx,mdx}",
        "./src/app/**/*.{js,ts,jsx,tsx,mdx}"
    ],
    theme: {
        extend: {
            colors: {
                background: "hsl(var(--background))",
                foreground: "hsl(var(--foreground))",
                card: "hsl(var(--card))",
                border: "hsl(var(--border))",
                primary: "hsl(var(--primary))",
                muted: "hsl(var(--muted))",
                success: "hsl(var(--success))",
                warning: "hsl(var(--warning))",
                danger: "hsl(var(--danger))"
            },
            borderRadius: {
                lg: "0.75rem",
                md: "0.5rem",
                sm: "0.375rem"
            }
        }
    },
    plugins: []
};
export default config;
