// 预测模块：对 rtt/吞吐量做 EWMA 平滑，判断是否进入弱网并给出建议动作。
// 不依赖 @ohos.net.connection 的类型，由调用方把采样指标传入即可。

/** 建议动作的显式联合类型（避免索引访问类型） */
export type ActionRecommendation = 'SWITCH_TO_CELLULAR' | 'KEEP_CURRENT';

/** 采样到的网络指标（由 NetworkMonitor 或调用方注入） */
export interface CurrentMetrics {
  /** 最近一次测得的往返时延（毫秒） */
  rttMs: number;
  /** 最近一次测得的下行吞吐（kbps；需与阈值单位一致） */
  throughputKbps: number;
  /** 可选：信号强度、时间戳等，便于扩展 */
  signalDbm?: number;
  ts?: number; // Date.now()
}

/** 预测器构造参数（提到顶层，避免内联对象字面量类型） */
export interface PredictorOptions {
  alpha?: number;           // EWMA 平滑系数（默认 0.3）
  rttHighMs?: number;       // RTT 高阈（默认 250ms）
  tpLowKbps?: number;       // 吞吐低阈（默认 800 kbps）
  needBadN?: number;        // 连续坏样本数 -> 弱网（默认 3）
  needGoodN?: number;       // 连续好样本数 -> 退出弱网（默认 4）
  actionLatencyMs?: number; // 建议动作预计生效时间（默认 1500ms）
}

/** 预测结果 */
export interface PredictionResult {
  willBeWeakNetwork: boolean;
  confidence: number;            // 0~1
  estimatedTimeMs: number;       // 建议动作的预计生效时间
  recommendedAction: ActionRecommendation;
  rttEwmaMs: number;             // 便于可视化/调试
  tpEwmaKbps: number;
}

/** ✔️ 名义类型：用于跨文件传参，避免 structural typing 报错 */
export class PredictorInput {
  public rttMs: number;
  public throughputKbps: number;
  constructor(rttMs: number, throughputKbps: number) {
    this.rttMs = rttMs;
    this.throughputKbps = throughputKbps;
  }
}

/** EWMA 预测器 */
export class NetworkPredictor {
  private alpha: number;
  private rttEwmaMs: number = NaN;
  private tpEwmaKbps: number = NaN;

  private rttHighMs: number;
  private tpLowKbps: number;

  private badCount: number = 0;
  private goodCount: number = 0;
  private readonly needBadN: number;
  private readonly needGoodN: number;

  private readonly actionLatencyMs: number;

  constructor(opts?: PredictorOptions) {
    this.alpha = Math.min(1, Math.max(0.01, opts?.alpha ?? 0.3));
    this.rttHighMs = opts?.rttHighMs ?? 250;
    this.tpLowKbps = opts?.tpLowKbps ?? 800;
    this.needBadN = opts?.needBadN ?? 3;
    this.needGoodN = opts?.needGoodN ?? 4;
    this.actionLatencyMs = opts?.actionLatencyMs ?? 1500;
  }

  /** 重置内部状态（如切网后调用） */
  public reset(): void {
    this.rttEwmaMs = NaN;
    this.tpEwmaKbps = NaN;
    this.badCount = 0;
    this.goodCount = 0;
  }

  /** 单步更新；返回最新预测结果（兼容接口或类实例） */
  public update(metrics: CurrentMetrics | PredictorInput): PredictionResult {
    const rtt = Math.max(0, metrics.rttMs);
    const tp = Math.max(0, metrics.throughputKbps);

    // EWMA: s_t = α·x_t + (1-α)·s_{t-1}
    if (Number.isNaN(this.rttEwmaMs)) this.rttEwmaMs = rtt;
    else this.rttEwmaMs = this.alpha * rtt + (1 - this.alpha) * this.rttEwmaMs;

    if (Number.isNaN(this.tpEwmaKbps)) this.tpEwmaKbps = tp;
    else this.tpEwmaKbps = this.alpha * tp + (1 - this.alpha) * this.tpEwmaKbps;

    // 判据：RTT 高于阈值 或 吞吐低于阈值 => 坏样本；否则好样本
    const isBad = (this.rttEwmaMs >= this.rttHighMs) || (this.tpEwmaKbps <= this.tpLowKbps);
    if (isBad) { this.badCount += 1; this.goodCount = 0; }
    else { this.goodCount += 1; this.badCount = 0; }

    const intoWeak = this.badCount >= this.needBadN;
    const exitWeak = this.goodCount >= this.needGoodN;

    // 滞回：优先进入/保持弱网，连续恢复后再退出
    let willBeWeakNetwork: boolean;
    if (intoWeak) willBeWeakNetwork = true;
    else if (exitWeak) willBeWeakNetwork = false;
    else willBeWeakNetwork = (this.rttEwmaMs >= this.rttHighMs) || (this.tpEwmaKbps <= this.tpLowKbps);

    const confidence = Math.min(1, Math.max(0, willBeWeakNetwork
      ? this.badCount / this.needBadN
      : this.goodCount / this.needGoodN));

    const recommendedAction: ActionRecommendation =
      willBeWeakNetwork ? 'SWITCH_TO_CELLULAR' : 'KEEP_CURRENT';

    return {
      willBeWeakNetwork,
      confidence,
      estimatedTimeMs: this.actionLatencyMs,
      recommendedAction,
      rttEwmaMs: this.rttEwmaMs,
      tpEwmaKbps: this.tpEwmaKbps
    };
  }
}
