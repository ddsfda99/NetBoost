// src/main/ets/model/performance/StatisticsAnalyzer.ets
// 统计分析模块：基于性能样本生成优化效果报告。
// 注意：ArkTS 不支持 any/unknown，需要使用显式类型。

/** 报告结构：性能对比结果 */
export interface AnalysisReport {
  /** 吞吐或速率提升百分比（如 0.2 代表提升 20%） */
  improvementRate: number;
  /** 成功率变化（如 0.9 代表 90%） */
  successRate: number;
  /** 样本数量，方便调试和展示 */
  sampleCount: number;
}

/** 分析模块 */
export class StatisticsAnalyzer {
  /**
   * 分析一组性能指标，返回优化效果对比
   * @param metrics 数值型性能指标数组（如吞吐率、成功率等）
   * @returns 分析报告
   */
  public analyze(metrics: number[]): AnalysisReport {
    const sampleCount = metrics.length;
    if (sampleCount === 0) {
      return {
        improvementRate: 0,
        successRate: 0,
        sampleCount: 0,
      };
    }

    // 模拟成功率和提升率计算逻辑（可按你的业务调整）
    const avg = metrics.reduce((sum, v) => sum + v, 0) / sampleCount;
    const improvementRate = avg; // 假设 metrics 数值就是提升百分比部分
    const successRate = avg >= 0 && avg <= 1 ? avg : Math.min(Math.max(avg, 0), 1);

    return {
      improvementRate,
      successRate,
      sampleCount,
    };
  }
}
