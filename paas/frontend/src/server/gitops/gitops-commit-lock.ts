const projectLocks = new Map<string, Promise<void>>();

export async function withGitOpsProjectLock<T>(projectName: string, fn: () => Promise<T>): Promise<T> {
    const key = projectName.trim().toLowerCase();
    const prior = projectLocks.get(key) ?? Promise.resolve();
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
        release = resolve;
    });
    const tail = prior.then(() => gate);
    projectLocks.set(key, tail);
    await prior;
    try {
        return await fn();
    }
    finally {
        release();
        if (projectLocks.get(key) === tail) {
            projectLocks.delete(key);
        }
    }
}

export async function sleepMs(ms: number): Promise<void> {
    await new Promise((resolve) => setTimeout(resolve, ms));
}
