// src/main/ets/model/navigator/NetworkNavigator.ets
// 网络领航员模块：用于在测试或模拟环境中“切换不同网络状态”
// ArkTS 规范支持类、方法、类型与日志调用。

/** 支持的网络场景类型（可扩展） */
export type NetScene = 'GOOD_WIFI' | 'WEAK_WIFI' | 'STRONG_CELL' | 'WEAK_CELL' | 'OFFLINE';

export class NetworkNavigator {
  /** 模拟网络场景；正式产品中无需，只用于测试使用 */
  public simulateNetworkScene(scene: NetScene): void {
    // 临时打印：若有 linter 报错，可以改成 console.info 或日志组件
    console.info(`[NetworkNavigator] Simulating network scene: ${scene}`);
    // 可以在这里触发回调、事件或 mock 网络状态变更逻辑
  }
}
