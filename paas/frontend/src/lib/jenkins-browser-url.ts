const LAB_JENKINS_PUBLIC = (typeof process !== "undefined" && process.env.NEXT_PUBLIC_JENKINS_URL?.replace(/\/+$/, "")) ||
    (typeof process !== "undefined" && process.env.NEXT_PUBLIC_JENKINS_PROBE_URL?.replace(/\/+$/, "")) ||
    "";
export function jenkinsUrlForBrowser(url: string | null | undefined, options?: {
    buildNumber?: number | null;
    jobName?: string;
}): string | null {
    const pub = LAB_JENKINS_PUBLIC;
    const job = options?.jobName?.trim() || "paas-deploy";
    const bn = options?.buildNumber;
    if (url?.trim()) {
        if (/\.svc\.cluster\.local/i.test(url)) {
            if (pub) {
                try {
                    return `${pub}${new URL(url).pathname}`;
                }
                catch {
                }
            }
            if (bn != null) {
                return pub ? `${pub}/job/${job}/${bn}` : null;
            }
            return null;
        }
        return url.trim();
    }
    if (pub && bn != null) {
        return `${pub}/job/${job}/${bn}`;
    }
    return pub || null;
}
