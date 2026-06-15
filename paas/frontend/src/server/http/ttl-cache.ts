type CacheEntry<T> = {
    value: T;
    expiresAt: number;
};

export class TtlCache<T> {
    private readonly store = new Map<string, CacheEntry<T>>();

    constructor(private readonly defaultTtlMs: number) {}

    get(key: string): T | undefined {
        const row = this.store.get(key);
        if (!row) {
            return undefined;
        }
        if (Date.now() >= row.expiresAt) {
            this.store.delete(key);
            return undefined;
        }
        return row.value;
    }

    set(key: string, value: T, ttlMs?: number): void {
        this.store.set(key, {
            value,
            expiresAt: Date.now() + (ttlMs ?? this.defaultTtlMs)
        });
    }

    async getOrSet(key: string, factory: () => Promise<T>, ttlMs?: number): Promise<T> {
        const cached = this.get(key);
        if (cached !== undefined) {
            return cached;
        }
        const value = await factory();
        this.set(key, value, ttlMs);
        return value;
    }
}
