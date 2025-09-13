/**
 * PerformanceMonitor.ts
 * - 统一记录每轮摘要（“骚数据”），并可做轻量聚合
 * - 既可单独使用（UI 端展示），也可与 bench 脚本配合
 *
 * 用法示例：
 *   const pm = new PerformanceMonitor();
 *   // 每轮跑完后：
 *   pm.push({
 *     mode: r.mode as any, wallTime: r.wallTime, totalTime: r.totalTime,
 *     pausedMs: r.pausedMs, totalBytes: r.totalBytes, probes: r.probes
 *   });
 *   const stats = pm.stats(); // { rounds, wall_avg, total_med, probe_pct, ... }
 */

export type ModeStr = 'WIFI_ONLY' | 'AUTO_SWITCH';

export type ProbeStats = {
  count: number;
  costMs: number;
};

export type RoundSummary = {
  mode: ModeStr;
  wallTime: number;     // s（含等待）
  totalTime: number;    // s（剔等待）
  pausedMs: number;     // ms
  totalBytes: number;   // 本轮总字节
  weakDetectIndex?: number;
  switchTriggerTs?: number;
  probes?: ProbeStats;
  // 可选：路径细分字节
  bytesWifi?: number;
  bytesCell?: number;
  // 可选：一致性校验（逐文件时长总和）
  sumPerFileTs?: number;  // s
};

function median(arr: number[]): number {
  if (!arr.length) return 0;
  const a = [...arr].sort((x, y) => x - y);
  const m = Math.floor(a.length / 2);
  return a.length % 2 ? a[m] : (a[m - 1] + a[m]) / 2;
}
function sum(a: number[]): number { return a.reduce((x, y) => x + y, 0); }
function avg(a: number[]): number { return a.length ? sum(a) / a.length : 0; }

export class PerformanceMonitor {
  private rounds: RoundSummary[] = [];

  /** 追加一轮摘要 */
  push(r: RoundSummary) { this.rounds.push(r); }

  /** 清空 */
  clear() { this.rounds = []; }

  /** 导出原始数组（用于写文件或调试） */
  export(): RoundSummary[] { return [...this.rounds]; }

  /**
   * 轻量聚合统计（整体）
   * - probe_pct：探测时间占比（相对 wallTime），如 0.006 = 0.6%
   * - consistency：sum(perFile.t)/totalTime 的范围
   */
  stats() {
    const n = this.rounds.length || 1;
    const wall = this.rounds.map(r => r.wallTime);
    const totl = this.rounds.map(r => r.totalTime);
    const paused = this.rounds.map(r => r.pausedMs / 1000);
    const bytes = this.rounds.map(r => r.totalBytes);

    const probeCost = sum(this.rounds.map(r => (r.probes?.costMs || 0)));
    const wallSumMs = sum(wall) * 1000;
    const probe_pct = wallSumMs > 0 ? (probeCost / wallSumMs) : 0;

    // 一致性：sum(perFile.t)/totalTime
    const consistency: number[] = [];
    for (const r of this.rounds) {
      if (typeof r.sumPerFileTs === 'number' && r.totalTime > 0) {
        consistency.push((r.sumPerFileTs / r.totalTime) * 100.0);
      }
    }

    const consistency_min = consistency.length ? Math.min(...consistency) : 0;
    const consistency_max = consistency.length ? Math.max(...consistency) : 0;

    return {
      rounds: this.rounds.length,
      wall_avg: avg(wall), wall_med: median(wall),
      total_avg: avg(totl), total_med: median(totl),
      paused_avg: avg(paused), bytes_avg: avg(bytes),
      probe_pct,
      consistency_min, consistency_max,
    };
  }

  /**
   * 分模式聚合（WIFI_ONLY / AUTO_SWITCH），便于在 UI 直接展示对比提升
   * 返回：{ WIFI_ONLY: {...}, AUTO_SWITCH: {...} }
   */
  byMode() {
    const groups: Record<ModeStr, RoundSummary[]> = {
      WIFI_ONLY: [], AUTO_SWITCH: []
    };
    for (const r of this.rounds) groups[r.mode]?.push(r);

    const pack = (arr: RoundSummary[]) => {
      const wall = arr.map(r => r.wallTime);
      const totl = arr.map(r => r.totalTime);
      const paused = arr.map(r => r.pausedMs / 1000);
      const probe = arr.map(r => (r.probes?.costMs || 0) / (r.wallTime * 10)); // 乘10是为了安全防 NaN，后面统一再处理
      const probe_pct_med = arr.length
        ? median(arr.map(r => {
        const cost = r.probes?.costMs || 0;
        return r.wallTime > 0 ? (cost / (r.wallTime * 1000)) * 100.0 : 0;
      }))
        : 0;

      // 一致性范围
      const cons: number[] = [];
      for (const r of arr) {
        if (typeof r.sumPerFileTs === 'number' && r.totalTime > 0) {
          cons.push((r.sumPerFileTs / r.totalTime) * 100.0);
        }
      }

      return {
        n: arr.length,
        wall_avg: avg(wall), wall_med: median(wall),
        total_avg: avg(totl), total_med: median(totl),
        paused_avg: avg(paused),
        probe_med_pct: probe_pct_med,
        consistency_min: cons.length ? Math.min(...cons) : 0,
        consistency_max: cons.length ? Math.max(...cons) : 0,
      };
    };

    return {
      WIFI_ONLY: pack(groups.WIFI_ONLY),
      AUTO_SWITCH: pack(groups.AUTO_SWITCH),
    };
  }

  /** 计算 totalTime 的相对提升（%）：(baseline - optimized)/baseline*100 */
  static improvementPct(baselineAvg: number, optimizedAvg: number): number {
    return baselineAvg > 0 ? (baselineAvg - optimizedAvg) / baselineAvg * 100.0 : 0;
  }
}
