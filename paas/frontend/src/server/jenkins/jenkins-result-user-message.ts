export function jenkinsResultUserMessage(result: string | null | undefined, logTail: string): string {
    if (result === "ABORTED") {
        return "Jenkins pipeline was cancelled or aborted.";
    }
    const r = result ?? "UNKNOWN";
    const base = `Build backend finished with result: ${r}`;
    if ((result === "FAILURE" || result === "UNSTABLE") && /exit code -2|process apparently never started/i.test(logTail)) {
        return `${base}. Jenkins lost contact with a long shell step (durable-task exit -2), often during dockerless crane pushes; classic Status is authoritative if Blue Ocean still shows green. Retry after updating the Jenkinsfile or check registry/network and JENKINS_CRANE_PUSH_TIMEOUT_MIN.`;
    }
    return base;
}
