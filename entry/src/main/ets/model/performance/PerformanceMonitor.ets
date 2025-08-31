// src/main/ets/model/performance/PerformanceMonitor.ets
// 性能监控模块：记录下载/请求的用时与字节数，汇总吞吐、成功率等指标。
// 设计原则：避免 any/unknown；全部使用显式类型与接口，符合 ArkTS 规则。

/** 网络类型（用于报表分组/展示，可按需扩展） */
export type NetType = 'WIFI' | 'CELLULAR' | 'ETHERNET' | 'UNKNOWN';

/** 单次任务/样本的性能度量 */
export interface PerfMetric {
  /** 任务开始时间戳（ms） */
  startMs: number;
  /** 任务结束时间戳（ms），必须 >= startMs */
  endMs: number;
  /** 成功传输的字节数（B） */
  bytes: number;
  /** 本次采用的网络类型（可选） */
  netType?: NetType;
  /** 是否成功完成（用于成功率统计） */
  success: boolean;
  /** 任务标识/来源（可选，便于调试与归因） */
  tag?: string;
}

/** 汇总的性能报表 */
export interface PerformanceReport {
  /** 统计样本数 */
  samples: number;
  /** 成功样本数与成功率（0~1） */
  successCount: number;
  successRate: number;

  /** 总时长（ms）与总字节（B） */
  totalDurationMs: number;
  totalBytes: number;

  /** 平均吞吐（kbps，千比特/秒），按总字节/总时长计算 */
  avgThroughputKbps: number;

  /** P50/P90/P99 时延（ms），便于观察抖动；若样本不足返回 0 */
  p50LatencyMs: number;
  p90LatencyMs: number;
  p99LatencyMs: number;
}

/** 工具：求百分位（输入为已排序的数组） */
function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.floor((p / 100) * (sorted.length - 1))));
  return sorted[idx];
}

export class PerformanceMonitor {
  private metrics: PerfMetric[] = [];

  /** 新增一条度量（会做基本校验与修正） */
  public recordMetric(metric: PerfMetric): void {
    // 基本约束与兜底：避免负时长/负字节
    const start = Math.max(0, metric.startMs);
    const end = Math.max(start, metric.endMs);
    const bytes = Math.max(0, metric.bytes);
    const cleaned: PerfMetric = {
      startMs: start,
      endMs: end,
      bytes,
      netType: metric.netType ?? 'UNKNOWN',
      success: metric.success,
      tag: metric.tag,
    };
    this.metrics.push(cleaned);
  }

  /** 便捷记录：直接给定用时与字节数 */
  public addSample(durationMs: number, bytes: number, ok: boolean, netType?: NetType, tag?: string): void {
    const now = Date.now();
    this.recordMetric({
      startMs: now - Math.max(0, durationMs),
      endMs: now,
      bytes: Math.max(0, bytes),
      success: ok,
      netType: netType ?? 'UNKNOWN',
      tag,
    });
  }

  /** 清空历史样本（切换场景/阶段时可调用） */
  public reset(): void {
    this.metrics = [];
  }

  /** 生成当前的性能报表（同步计算） */
  public getPerformanceReport(): PerformanceReport {
    const n = this.metrics.length;
    if (n === 0) {
      return {
        samples: 0,
        successCount: 0,
        successRate: 0,
        totalDurationMs: 0,
        totalBytes: 0,
        avgThroughputKbps: 0,
        p50LatencyMs: 0,
        p90LatencyMs: 0,
        p99LatencyMs: 0,
      };
    }

    let totalBytes = 0;
    let totalDurationMs = 0;
    let successCount = 0;

    const latencies: number[] = new Array<number>(n);
    let i = 0;

    for (const m of this.metrics) {
      const dur = Math.max(0, m.endMs - m.startMs);
      totalDurationMs += dur;
      totalBytes += m.bytes;
      if (m.success) successCount += 1;
      latencies[i++] = dur;
    }

    // 排序后计算百分位
    latencies.sort((a, b) => a - b);

    // 平均吞吐（kbps）：(总字节 * 8 / 1000) / (总时长 / 1000)
    const avgThroughputKbps =
      totalDurationMs > 0 ? (totalBytes * 8) / totalDurationMs : 0;

    const report: PerformanceReport = {
      samples: n,
      successCount,
      successRate: successCount / n,
      totalDurationMs,
      totalBytes,
      avgThroughputKbps,
      p50LatencyMs: percentile(latencies, 50),
      p90LatencyMs: percentile(latencies, 90),
      p99LatencyMs: percentile(latencies, 99),
    };

    return report;
  }
}
