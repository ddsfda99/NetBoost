/**
 * NetProbe.ts
 * - 低频 Range 1B 探测 RTT，统计调用次数与耗时，用于报告“探测开销 <1%”
 * - 自适应：若近期疑似弱网，可短期将间隔从 N 调整为 N/2
 */
import { downloadRangeAppend } from './HttpDownloader';
import fs from '@ohos.file.fs';

export class NetProbe {
  private everyN: number;
  private counter = 0;
  private fastUntil = 0;   // fast 模式截止时间戳
  private stats = { count: 0, costMs: 0 };

  constructor(everyN = 10) { this.everyN = Math.max(2, everyN); }

  /** 在第 idx 个任务时决定是否探测；返回是否执行了探测 */
  async maybeProbe(idx: number, sampleUrl: string): Promise<boolean> {
    const now = Date.now();
    const interval = (now < this.fastUntil) ? Math.max(2, Math.floor(this.everyN / 2)) : this.everyN;

    if ((idx % interval) !== 0) return false;

    const tmp = `/storage/Users/currentUser/Download/.netprobe_tmp`;
    try { fs.unlinkSync(tmp); } catch {}
    const t0 = Date.now();
    try {
      // 只拉 1 个字节：bytes=0-0
      await downloadRangeAppend(sampleUrl, tmp, 0, 0, { connectMs: 5000, readMs: 5000 });
    } catch {}
    const cost = Date.now() - t0;
    this.stats.count += 1;
    this.stats.costMs += cost;
    try { fs.unlinkSync(tmp); } catch {}
    return true;
  }

  /** 当检测器置信度较高时，进入短期“快探测” */
  boostShort(durationMs = 15000) { this.fastUntil = Math.max(this.fastUntil, Date.now() + durationMs); }

  snapshot() { return { ...this.stats }; }
}
