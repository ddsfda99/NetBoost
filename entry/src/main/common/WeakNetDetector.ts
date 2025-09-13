export type WeakDecision = { isWeak: boolean; confidence: number };

export interface WeakParams {
  ewmaAlpha?: number;
  cusumK?: number;
  cusumH?: number;
  gateRatio?: number;
  fuseAlpha?: number;   // 速率权重（-zSpeed）
  fuseGamma?: number;   // 失败率权重
  winSize?: number;     // 失败率窗口
  warmupMin?: number;
}

export class WeakNetDetector {
  private ewma = 0;
  private hist: number[] = [];
  private failWin: number[] = [];
  private cfg: Required<WeakParams>;
  private cusumPos = 0;
  private cusumNeg = 0;

  constructor(params: WeakParams = {}) {
    this.cfg = {
      ewmaAlpha: 0.2,
      cusumK: 0.3,
      cusumH: 1.2,
      gateRatio: 0.5,
      fuseAlpha: 0.7,
      fuseGamma: 0.3,
      winSize: 20,
      warmupMin: 10,
      ...params,
    } as Required<WeakParams>;
  }

  private static clamp01(x: number) { return Math.max(0, Math.min(1, x)); }
  private static safeDiv(a: number, b: number, eps = 1e-6) {
    return a / (Math.abs(b) < eps ? (b >= 0 ? eps : -eps) : b);
  }
  private baseline(): number {
    const n = this.hist.length;
    if (n === 0) return 0;
    const sorted = this.hist.slice().sort((a, b) => a - b);
    const k = Math.max(1, Math.floor(n * 0.25));
    const low = sorted.slice(0, k);
    const s = low.reduce((a, b) => a + b, 0);
    return s / k;
  }

  feed(speedKBps: number, _ttfbMs?: number, ok: boolean = true): WeakDecision {
    const v = Number.isFinite(speedKBps) ? Math.max(0, speedKBps) : 0;

    // EWMA & 历史
    this.ewma = this.hist.length === 0 ? v : this.cfg.ewmaAlpha * v + (1 - this.cfg.ewmaAlpha) * this.ewma;
    this.hist.push(v);

    // 失败窗口
    this.failWin.push(ok ? 0 : 1);
    if (this.failWin.length > this.cfg.winSize) this.failWin.shift();
    const failRate = this.failWin.length ? this.failWin.reduce((a, b) => a + b, 0) / this.failWin.length : 0;

    // 基线与相对变化
    const baseRaw = this.baseline();
    const base = baseRaw > 0 ? baseRaw : (v > 0 ? v : 1e-3);
    const x = WeakNetDetector.safeDiv(v - base, Math.max(1e-3, base)); // 相对变化

    // CUSUM
    this.cusumPos = Math.max(0, this.cusumPos + (x - this.cfg.cusumK));
    this.cusumNeg = Math.min(0, this.cusumNeg + (x + this.cfg.cusumK));
    const change = (this.cusumPos > this.cfg.cusumH) || (Math.abs(this.cusumNeg) > this.cfg.cusumH);

    // 融合打分（去 TTFB）：越大越弱
    const zSpeed = WeakNetDetector.safeDiv(v - base, Math.max(1e-3, base)); // 负向为弱
    const score = this.cfg.fuseAlpha * (-zSpeed) + this.cfg.fuseGamma * failRate;
    const weakByScore = score > 0.5;

    // 门控
    const gate = this.ewma < this.cfg.gateRatio * base;

    // 冷启动
    const enough = this.hist.length >= Math.max(3, this.cfg.warmupMin);
    const isWeak = !!(enough && change && weakByScore && gate);

    // 置信度
    const confDrop = WeakNetDetector.clamp01(base > 0 ? (base - this.ewma) / base : 0);
    const cusumMag = Math.min(1, Math.max(0, Math.max(this.cusumPos, Math.abs(this.cusumNeg)) / (this.cfg.cusumH * 2)));
    const confidence = WeakNetDetector.clamp01(0.45 * confDrop + 0.35 * failRate + 0.20 * cusumMag);

    if (isWeak) { this.cusumPos *= 0.25; this.cusumNeg *= 0.25; }
    return { isWeak, confidence };
  }

  reset() {
    this.ewma = 0; this.hist = []; this.failWin = []; this.cusumPos = 0; this.cusumNeg = 0;
  }
}
