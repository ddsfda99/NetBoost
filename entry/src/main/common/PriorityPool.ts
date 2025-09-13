/**
 * PriorityPool.ts
 * - 两级优先队列：small 优先于 large
 * - 动态调整并发 setLimit(n)
 * - idle() 等待任务清空
 */
export class PriorityPool {
  private limit: number;
  private running = 0;
  private small: Array<() => Promise<void>> = [];
  private large: Array<() => Promise<void>> = [];
  private pumping = false;

  constructor(limit: number) { this.limit = Math.max(1, limit); }

  setLimit(n: number) {
    this.limit = Math.max(1, n);
    this.pump();
  }

  push(task: () => Promise<void>, small = false) {
    (small ? this.small : this.large).push(task);
    this.pump();
  }

  private next(): (() => Promise<void>) | undefined {
    return this.small.shift() || this.large.shift();
  }

  private pump() {
    if (this.pumping) return;
    this.pumping = true;
    try {
      while (this.running < this.limit) {
        const t = this.next();
        if (!t) break;
        this.running++;
        t().finally(() => {
          this.running--;
          this.pumping = false;
          this.pump();
        });
      }
    } finally {
      this.pumping = false;
    }
  }

  idle(): Promise<void> {
    return new Promise(res => {
      const tick = () => (this.running === 0 && this.small.length === 0 && this.large.length === 0)
        ? res() : setTimeout(tick, 50);
      tick();
    });
  }

  snapshot() {
    return { running: this.running, smallQ: this.small.length, largeQ: this.large.length, limit: this.limit };
  }
}
