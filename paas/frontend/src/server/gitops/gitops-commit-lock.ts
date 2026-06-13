const repoLocks = new Map<string, Promise<void>>();

async function withAsyncLock<T>(key: string, store: Map<string, Promise<void>>, fn: () => Promise<T>): Promise<T> {
    const prior = store.get(key) ?? Promise.resolve();
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
        release = resolve;
    });
    const tail = prior.then(() => gate);
    store.set(key, tail);
    await prior;
    try {
        return await fn();
    }
    finally {
        release();
        if (store.get(key) === tail) {
            store.delete(key);
        }
    }
}

export async function withGitOpsRepoLock<T>(repoKey: string, fn: () => Promise<T>): Promise<T> {
    const key = repoKey.trim().toLowerCase() || "default";
    return withAsyncLock(key, repoLocks, fn);
}

const projectLocks = new Map<string, Promise<void>>();

export async function withGitOpsProjectLock<T>(projectName: string, fn: () => Promise<T>): Promise<T> {
    const key = projectName.trim().toLowerCase();
    return withAsyncLock(key, projectLocks, fn);
}

export async function sleepMs(ms: number): Promise<void> {
    await new Promise((resolve) => setTimeout(resolve, ms));
}
