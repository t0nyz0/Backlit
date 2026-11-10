/** Bounded FIFO preserves multi-action ordering without idle work or subprocess bursts. */
export class CommandQueue {
    private tail: Promise<void> = Promise.resolve();
    private pending = 0;
    private readonly send: (link: string) => Promise<void>;
    private readonly capacity: number;
    private readonly now: () => number;
    constructor(send: (link: string) => Promise<void>, capacity = 32, now = () => performance.now()) {
        if (!Number.isInteger(capacity) || capacity < 1 || capacity > 128) throw new Error("Invalid queue capacity");
        this.send = send; this.capacity = capacity; this.now = now;
    }
    enqueue(link: string): Promise<void> {
        if (this.pending >= this.capacity) return Promise.reject(new Error("Backlit action queue is full"));
        this.pending++;
        const enqueued = this.now();
        const result = this.tail.then(() => {
            if (this.now() - enqueued > 2000) throw new Error("Backlit action expired while waiting");
            return this.send(link);
        });
        // A failed launcher must not prevent later Off/On actions from running.
        this.tail = result.then(() => undefined, () => undefined);
        return result.finally(() => { this.pending--; });
    }
}
