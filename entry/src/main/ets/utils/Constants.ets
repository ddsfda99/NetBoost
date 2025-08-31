export const DEFAULT_CONCURRENCY: number = 4;

// 预测：EWMA 权重与触发阈值（与 Index.ets 一致的经验数值）
export const EWMA_ALPHA: number = 0.3;
export const RTT_UP_FACTOR: number = 1.3;
export const TP_DOWN_FACTOR: number = 0.7;
export const BAD_CNT_TRIGGER: number = 3;

// HTTP 默认超时
export const CONNECT_TIMEOUT_MS: number = 8000;
export const READ_TIMEOUT_MS: number = 20000;

// UI
export const MAX_LOG_LINES: number = 2000;
