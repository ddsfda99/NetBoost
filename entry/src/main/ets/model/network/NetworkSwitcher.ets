// src/main/ets/model/network/NetworkSwitcher.ets
// 作用：为应用绑定/切换到指定网络（例如蜂窝），或恢复默认网络。

import connection from '@ohos.net.connection';

/** ArkTS 允许抛出的自定义错误类型（必须继承自 Error） */
class SwitcherError extends Error {
  readonly code: number;
  constructor(code: number, message: string) {
    super(message);
    this.code = code;
    // 兼容部分运行时对自定义错误名的显示
    this.name = 'SwitcherError';
  }
}

// 自定义错误码（示例）
enum SwitcherErr {
  NO_DEFAULT_NET = 10001,
  INVALID_HANDLE = 10002,
}

export class NetworkSwitcher {
  private currentHandle: connection.NetHandle | null = null;

  /** 绑定到指定网络（如蜂窝）。调用方需保证 preferred 有效且已可用。 */
  public async bindTo(preferred: connection.NetHandle): Promise<void> {
    if (!preferred || typeof preferred.netId !== 'number' || preferred.netId === 0) {
      // ArkTS limited-throw：只能抛出 Error 或其子类
      throw new SwitcherError(SwitcherErr.INVALID_HANDLE, '[NetworkSwitcher] invalid NetHandle');
    }
    if (this.currentHandle && this.currentHandle.netId === preferred.netId) {
      return; // 已绑定同一网络，无需重复
    }
    await connection.setAppNet(preferred); // 绑定到指定网络
    this.currentHandle = preferred;
  }

  /** 绑定回默认网络（等价于取消 App 级别绑定）。 */
  public async bindToDefault(): Promise<void> {
    const def = await connection.getDefaultNet();
    if (!def || def.netId === 0) {
      throw new SwitcherError(SwitcherErr.NO_DEFAULT_NET, '[NetworkSwitcher] no default network');
    }
    await connection.setAppNet(def);
    this.currentHandle = def;
  }

  /** 应用是否已绑定到某个非 0 的网络。 */
  public async isBound(): Promise<boolean> {
    const appNet = await connection.getAppNet();
    return !!appNet && appNet.netId !== 0;
  }

  /** 获取当前生效的网络句柄（优先返回已绑定网络，否则返回默认网络）。 */
  public async getActiveHandle(): Promise<connection.NetHandle> {
    const appNet = await connection.getAppNet();
    if (appNet && appNet.netId !== 0) {
      this.currentHandle = appNet;
      return appNet;
    }
    const def = await connection.getDefaultNet();
    this.currentHandle = def;
    return def;
  }
}
