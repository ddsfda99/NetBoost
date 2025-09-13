/**
 * NetworkNavigator.ets
 * - 挑战项“网络领航员”的软封装（ROM/SDK 不支持时安全 no-op）
 * - 严格符合 ArkTS 规则：不使用 any/unknown；不使用未类型化对象字面量；不使用索引签名
 *
 * 用法（可选）：
 *   const nav = new NetworkNavigator();
 *   nav.simulateGarage();
 *   nav.simulateLeavingHome();
 *   // 自定义
 *   nav.simulateCustom(new CustomParams('myCase', 220, 120, 3, 1500));
 *
 * 若后续接入系统能力，可实现 INavigatorAdapter，并通过 attachAdapter(adapter) 注入。
 */

export type SceneName = 'garage' | 'leaving_home' | 'custom';

/** 地库场景参数（高时延/高抖动/丢包/限速） */
export class GarageParams {
  readonly rttMs: number;
  readonly jitterMs: number;
  readonly lossPct: number;   // 0~100
  readonly downKbps: number;

  constructor(rttMs: number, jitterMs: number, lossPct: number, downKbps: number) {
    this.rttMs = rttMs;
    this.jitterMs = jitterMs;
    this.lossPct = lossPct;
    this.downKbps = downKbps;
  }
}

/** 离家场景参数（Wi-Fi RSSI 随时间衰减） */
export class LeavingHomeParams {
  readonly wifiRssiStart: number;
  readonly wifiRssiEnd: number;
  readonly durationMs: number;

  constructor(wifiRssiStart: number, wifiRssiEnd: number, durationMs: number) {
    this.wifiRssiStart = wifiRssiStart;
    this.wifiRssiEnd = wifiRssiEnd;
    this.durationMs = durationMs;
  }
}

/**
 * 自定义场景参数（给出一个名字 + 若干受限可选标量）。
 * 注意：不用索引签名；所有可选字段都显式列出。
 */
export class CustomParams {
  readonly name: string;
  readonly rttMs?: number;
  readonly jitterMs?: number;
  readonly lossPct?: number;
  readonly downKbps?: number;
  readonly wifiRssiStart?: number;
  readonly wifiRssiEnd?: number;
  readonly durationMs?: number;

  constructor(
    name: string,
    rttMs?: number,
    jitterMs?: number,
    lossPct?: number,
    downKbps?: number,
    wifiRssiStart?: number,
    wifiRssiEnd?: number,
    durationMs?: number
  ) {
    this.name = name;
    this.rttMs = rttMs;
    this.jitterMs = jitterMs;
    this.lossPct = lossPct;
    this.downKbps = downKbps;
    this.wifiRssiStart = wifiRssiStart;
    this.wifiRssiEnd = wifiRssiEnd;
    this.durationMs = durationMs;
  }
}

/** 统一的场景参数联合类型 */
export type SceneParams = GarageParams | LeavingHomeParams | CustomParams;

/** 可选的系统适配器接口（后续真接入系统能力时实现它并注入） */
export interface INavigatorAdapter {
  simulate(scene: SceneName, params: SceneParams): boolean;
  stop(): boolean;
}

export class NetworkNavigator {
  private available: boolean = false;
  private adapter: INavigatorAdapter | undefined;

  /** 注入系统适配器（有则可用；无则保持软关闭） */
  attachAdapter(adapter: INavigatorAdapter): void {
    this.adapter = adapter;
    this.available = true;
  }

  /** 当前 ROM/SDK 能力是否可用 */
  isAvailable(): boolean { return this.available; }

  /** 通用模拟入口（内部统一处理） */
  private doSimulate(scene: SceneName, params: SceneParams): boolean {
    if (!this.available || !this.adapter) {
      // 软关闭：仅打印日志，不报错
      console.info('[Navigator] simulate skipped (unavailable):', scene);
      return false;
    }
    try {
      return this.adapter.simulate(scene, params);
    } catch (e) {
      console.warn('[Navigator] simulate failed:', e);
      return false;
    }
  }

  /** 典型：地库 */
  simulateGarage(): boolean {
    const p = new GarageParams(200, 150, 5, 1000);
    return this.doSimulate('garage', p);
  }

  /** 典型：离家（Wi-Fi 渐弱） */
  simulateLeavingHome(): boolean {
    const p = new LeavingHomeParams(-55, -85, 30000);
    return this.doSimulate('leaving_home', p);
  }

  /** 自定义场景（显式类实例，避免未类型化对象字面量） */
  simulateCustom(params: CustomParams): boolean {
    return this.doSimulate('custom', params);
  }

  /** 停止模拟 */
  stopSimulation(): boolean {
    if (!this.available || !this.adapter) { return false; }
    try {
      return this.adapter.stop();
    } catch (e) {
      console.warn('[Navigator] stop failed:', e);
      return false;
    }
  }
}
