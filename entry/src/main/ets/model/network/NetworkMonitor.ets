// src/main/ets/model/network/NetworkMonitor.ets
// 网络监测模块（@ohos.net.connection）
// 关键点：事件挂在 NetConnection 实例；先 register 再 on；停止用 unregister；
//        回调参数的对象类型用 interface 提前声明，避免 ArkTS “no-obj-literals-as-types”。

import connection from '@ohos.net.connection';
import { BusinessError } from '@ohos.base';

/** netCapabilitiesChange 事件回调参数 */
interface NetCapChangeEvent {
  netHandle: connection.NetHandle;
  netCap: connection.NetCapabilities;
}

/** netConnectionPropertiesChange 事件回调参数 */
interface NetConnPropsChangeEvent {
  netHandle: connection.NetHandle;
  connectionProperties: connection.ConnectionProperties;
}

export class NetworkMonitor {
  private netConn: connection.NetConnection | null = null;
  private started = false;

  constructor() {
    // 关注默认网络（不传 NetSpecifier）
    this.netConn = connection.createNetConnection();
  }

  /** 是否存在默认数据网络 */
  public async hasDefaultNet(): Promise<boolean> {
    return await connection.hasDefaultNet();
  }

  /** 获取默认网络句柄 */
  public async getDefaultHandle(): Promise<connection.NetHandle> {
    return await connection.getDefaultNet();
  }

  /** 获取当前网络能力（含 bearerTypes 等） */
  public async getNetCapabilities(): Promise<connection.NetCapabilities> {
    const handle = await this.getDefaultHandle();
    return await connection.getNetCapabilities(handle);
  }

  /** 获取当前网络属性（路由/接口/MTU 等） */
  public async getConnectionProperties(): Promise<connection.ConnectionProperties> {
    const handle = await this.getDefaultHandle();
    return await connection.getConnectionProperties(handle);
  }

  /** 推断当前网络类型（WIFI / CELLULAR / ETHERNET / UNKNOWN） */
  public async getNetworkType(): Promise<'WIFI' | 'CELLULAR' | 'ETHERNET' | 'UNKNOWN'> {
    const caps = await this.getNetCapabilities();
    const types = Array.from(caps.bearerTypes?.values?.() ?? []);
    if (types.includes(connection.NetBearType.BEARER_WIFI)) return 'WIFI';
    if (types.includes(connection.NetBearType.BEARER_CELLULAR)) return 'CELLULAR';
    if (types.includes(connection.NetBearType.BEARER_ETHERNET)) return 'ETHERNET';
    return 'UNKNOWN';
  }

  /** 启动网络监测（register + 订阅事件） */
  public startMonitor(): void {
    if (!this.netConn || this.started) return;

    // 先 register，才能收到后续 on 回调
    this.netConn.register((err: BusinessError) => {
      if (err) {
        console.error('[NetworkMonitor] register failed: ' + JSON.stringify(err));
        return;
      }
      console.info('[NetworkMonitor] register ok');
    });

    // 可用 / 丢失
    this.netConn.on('netAvailable', (handle: connection.NetHandle) => {
      console.info('[NetworkMonitor] netAvailable: ' + JSON.stringify(handle));
    });
    this.netConn.on('netLost', (handle: connection.NetHandle) => {
      console.warn('[NetworkMonitor] netLost: ' + JSON.stringify(handle));
    });

    // 能力变化（回调为一个对象，使用上面的 interface）
    this.netConn.on('netCapabilitiesChange', (data: NetCapChangeEvent) => {
      console.info('[NetworkMonitor] netCapabilitiesChange: ' + JSON.stringify(data.netCap));
    });

    // 连接属性变化（同理为对象参数）
    this.netConn.on('netConnectionPropertiesChange', (data: NetConnPropsChangeEvent) => {
      console.info('[NetworkMonitor] netConnectionPropertiesChange: ' + JSON.stringify(data.connectionProperties));
    });

    // （可选）不可用事件
    this.netConn.on('netUnavailable', () => {
      console.warn('[NetworkMonitor] netUnavailable');
    });

    this.started = true;
  }

  /** 停止网络监测（只需 unregister） */
  public stopMonitor(): void {
    if (!this.netConn || !this.started) return;
    this.netConn.unregister((err: BusinessError) => {
      if (err) {
        console.error('[NetworkMonitor] unregister failed: ' + JSON.stringify(err));
      } else {
        console.info('[NetworkMonitor] unregister ok');
      }
    });
    this.started = false;
  }
}
