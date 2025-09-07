/**
 * HttpDownloader.ts
 *
 * 本模块封装了 HTTP 下载的多网络支持：
 *
 * 1. 网络绑定：
 *    - 可以将单个 HttpRequest 绑定到指定网络路径（Wi-Fi / 蜂窝）。
 *    - 优先使用“每请求级绑定”，若不支持则退化为“应用级绑定”。
 *    - 应用级绑定使用后会立即解绑，避免影响进程全局。
 *
 * 2. 单路下载：
 *    - download()：使用系统默认网络（通常是 Wi-Fi）。
 *    - requestWithPrefer()：按偏好绑定到 Wi-Fi 或蜂窝发起请求。
 *
 * 3. 双路并发：
 *    - requestDual()：同时通过 Wi-Fi 与蜂窝发起请求，谁先返回即采用谁。
 *    - 在不支持每请求绑定的环境下，会自动降级为 Wi-Fi 单路。
 *
 * 4. 封装写盘：
 *    - downloadWithChoice()：支持 'wifi' 或 'dual' 策略下载并写入文件。
 *    - 返回耗时、文件大小、实际使用的网络（wifi/cell）。
 *
 * 适用场景：
 * - 弱网优化实验：比较 Wi-Fi 单路与双路并发在不同环境下的耗时表现。
 * - 控制蜂窝流量消耗：仅在首屏或弱网时启用双路，其余保持 Wi-Fi。
 *
 * 依赖：
 * - @ohos.net.http
 * - @ohos.file.fs
 * - @kit.NetworkKit
 *
 * 权限要求（module.json5）：
 * - ohos.permission.INTERNET
 * - ohos.permission.GET_NETWORK_INFO
 */

import http from '@ohos.net.http';
import fs from '@ohos.file.fs';
import { connection } from '@kit.NetworkKit';

/**
 * ========= NetHandle 缓存与解析 =========
 */
type PathKind = 'wifi' | 'cell';
interface NetCache {
  wifi?: connection.NetHandle | null;
  cell?: connection.NetHandle | null;
  def?: connection.NetHandle | null; // default
}
const NET_CACHE: NetCache = { wifi: undefined, cell: undefined, def: undefined };

/** 读取所有已连接网络，按 bearer 筛选 Wi-Fi / 蜂窝，并缓存 */
async function resolveHandles(): Promise<void> {
  if (NET_CACHE.wifi !== undefined && NET_CACHE.cell !== undefined && NET_CACHE.def !== undefined) return;

  try {
    NET_CACHE.def = await connection.getDefaultNet();
  } catch {
    NET_CACHE.def = { netId: 0 } as connection.NetHandle;
  }

  let nets: connection.NetHandle[] = [];
  try {
    // 所有“激活”的数据网络（可能包含 Wi-Fi 与蜂窝）
    // @ts-ignore - 类型由 SDK 提供
    nets = await connection.getAllNets?.() ?? [];
  } catch {
    nets = [];
  }

  const tasks = nets.map(async (h) => {
    try {
      const cap = await connection.getNetCapabilities(h);
      const bears = cap?.bearerTypes || [];
      if (bears.includes(connection.NetBearType.BEARER_WIFI)) {
        NET_CACHE.wifi = h;
      }
      if (bears.includes(connection.NetBearType.BEARER_CELLULAR)) {
        NET_CACHE.cell = h;
      }
    } catch { /* ignore */ }
  });
  await Promise.all(tasks);

  if (NET_CACHE.wifi === undefined) NET_CACHE.wifi = null;
  if (NET_CACHE.cell === undefined) NET_CACHE.cell = null;
  if (NET_CACHE.def  === undefined) NET_CACHE.def  = null;
}

/** 取指定路径的 NetHandle；若无则抛错 */
async function getHandleFor(path: PathKind): Promise<connection.NetHandle> {
  await resolveHandles();
  const h = NET_CACHE[path];
  if (h && typeof h.netId === 'number' && h.netId !== 0) return h;
  throw new Error(`No active ${path.toUpperCase()} network available`);
}

/** 从指定 URL 下载二进制文件并保存到本地路径，同时返回下载耗时和文件大小，用于WIFI_ONLY模式 */
export async function download(url: string, dstPath: string): Promise<{ elapsed: number; size: number }> {
  const req = http.createHttp();
  const start = Date.now();

  return new Promise((resolve, reject) => {
    req.request(
      url,
      {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 60000,
        readTimeout: 600000,
      },
      (err, data) => {
        const end = Date.now();
        if (err) {
          req.destroy();
          reject(err);
          return;
        }

        const arr = data.result as ArrayBuffer;
        let file: fs.File | undefined;

        try {
          // 打开文件（不存在则创建）
          file = fs.openSync(dstPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
          // 直接写入 ArrayBuffer
          fs.writeSync(file.fd, arr);
        } catch (e) {
          if (file) {
            try { fs.closeSync(file); } catch {}
          }
          req.destroy();
          reject(e);
          return;
        }

        // 关闭资源
        try { fs.closeSync(file!); } catch {}
        req.destroy();

        resolve({ elapsed: (end - start) / 1000.0, size: arr.byteLength });
      }
    );
  });
}

/**
 * ========= 指定路径绑定：优先每请求绑定；否则应用级绑定并返回解绑器 =========
 * 返回一个 async unbind()，在请求结束后调用。
 */
async function bindToPath(req: http.HttpRequest, path: PathKind): Promise<() => Promise<void>> {
  const handle = await getHandleFor(path);

  // A) 每请求级绑定：req.bindNet(NetHandle)
  const anyReq = req as unknown as { bindNet?: (h: connection.NetHandle) => Promise<void> | void };
  if (typeof anyReq.bindNet === 'function') {
    await Promise.resolve(anyReq.bindNet!(handle));
    // 每请求绑定无需额外解绑
    return async () => {};
  }

  // B) 应用级绑定：connection.setAppNet / clearAppNet
  // 注意：这是进程全局的，会与并发请求冲突，因此双路并发时不能使用。
  const anyConn = connection as unknown as {
    setAppNet?: (h: connection.NetHandle) => Promise<void> | void;
    clearAppNet?: () => Promise<void> | void;
  };

  if (typeof anyConn.setAppNet === 'function' && typeof anyConn.clearAppNet === 'function') {
    await Promise.resolve(anyConn.setAppNet!(handle));
    return async () => { await Promise.resolve(anyConn.clearAppNet!()); };
  }

  // C) 都不支持：直接报错
  throw new Error('Per-request or app-level network binding API is not available on this runtime');
}

/**
 * ========= 按偏好单路请求 =========
 */
export function requestWithPrefer(
  url: string,
  prefer: PathKind
): Promise<{ arrayBuffer: ArrayBuffer; elapsedSec: number }> {
  const req = http.createHttp();
  const start = Date.now();

  let unbind: (() => Promise<void>) | null = null;

  return new Promise(async (resolve, reject) => {
    try {
      unbind = await bindToPath(req, prefer);
    } catch (e) {
      // 若绑定失败（例如没有该路径），直接报错
      try { req.destroy(); } catch {}
      reject(e);
      return;
    }

    req.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 60000,
      readTimeout: 600000,
    }, async (err, data) => {
      const end = Date.now();
      const finalize = async () => {
        try { if (unbind) await unbind(); } catch {}
        try { req.destroy(); } catch {}
      };

      if (err) { await finalize(); reject(err); return; }

      try {
        const buf = data.result as ArrayBuffer;
        resolve({ arrayBuffer: buf, elapsedSec: (end - start)/1000 });
      } finally {
        await finalize();
      }
    });
  });
}

/**
 * ========= 双路并发（Wi-Fi / 蜂窝），谁先返回用谁 =========
 * 仅当支持“每请求绑定”时启用并发；否则自动降级为 Wi-Fi 单路。
 */
export async function requestDual(
  url: string
): Promise<{ arrayBuffer: ArrayBuffer; elapsedSec: number; winner: 'wifi'|'cell' }> {

  // 探测是否支持每请求绑定（看一个临时 request 是否有 bindNet）
  const probe = http.createHttp() as unknown as { bindNet?: Function };
  const supportsPerRequestBind = typeof probe.bindNet === 'function';
  try { (probe as any).destroy?.(); } catch {}

  if (!supportsPerRequestBind) {
    // 应用级绑定会相互抢占，无法安全并发：退化为 Wi-Fi 单路
    const r = await requestWithPrefer(url, 'wifi');
    return { arrayBuffer: r.arrayBuffer, elapsedSec: r.elapsedSec, winner: 'wifi' };
  }

  // —— 真正的双路并发 —— //
  const reqWifi = http.createHttp();
  const reqCell = http.createHttp();

  let unbindWifi: (() => Promise<void>) | null = null;
  let unbindCell: (() => Promise<void>) | null = null;

  try {
    unbindWifi = await bindToPath(reqWifi, 'wifi');
    unbindCell = await bindToPath(reqCell, 'cell');
  } catch (e) {
    try { reqWifi.destroy(); } catch {}
    try { reqCell.destroy(); } catch {}
    if (unbindWifi) { try { await unbindWifi(); } catch {} }
    if (unbindCell) { try { await unbindCell(); } catch {} }
    throw e;
  }

  const start = Date.now();
  return new Promise((resolve, reject) => {
    let settled = false;

    const finish = async (winner: 'wifi'|'cell', buf: ArrayBuffer) => {
      if (settled) return;
      settled = true;
      try { reqWifi.destroy(); } catch {}
      try { reqCell.destroy(); } catch {}
      try { if (unbindWifi) await unbindWifi(); } catch {}
      try { if (unbindCell) await unbindCell(); } catch {}
      resolve({ arrayBuffer: buf, elapsedSec: (Date.now()-start)/1000, winner });
    };

    const failOnce = async (err: any) => {
      if (settled) return;
      settled = true;
      try { reqWifi.destroy(); } catch {}
      try { reqCell.destroy(); } catch {}
      try { if (unbindWifi) await unbindWifi(); } catch {}
      try { if (unbindCell) await unbindCell(); } catch {}
      reject(err);
    };

    reqWifi.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 60000, readTimeout: 600000,
    }, (err, data) => {
      if (err) { failOnce(err); return; }
      finish('wifi', data.result as ArrayBuffer);
    });

    reqCell.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 60000, readTimeout: 600000,
    }, (err, data) => {
      if (err) { failOnce(err); return; }
      finish('cell', data.result as ArrayBuffer);
    });
  });
}

/**
 * ========= Auto Switch：根据 choice 下载并写盘，返回赢家 =========
 */
export async function downloadWithChoice(
  url: string,
  dstPath: string,
  choice: 'wifi' | 'dual'   // Wi-Fi 或 双路
): Promise<{ elapsed: number; size: number; path: 'wifi' | 'cell' }> {
  let buf: ArrayBuffer, elapsed: number, winner: 'wifi'|'cell' = 'wifi';

  if (choice === 'dual') {
    const r = await requestDual(url);
    buf = r.arrayBuffer; elapsed = r.elapsedSec; winner = r.winner;
  } else {
    const r = await requestWithPrefer(url, 'wifi');
    buf = r.arrayBuffer; elapsed = r.elapsedSec; winner = 'wifi';
  }

  let file: fs.File | undefined;
  try {
    file = fs.openSync(dstPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    fs.writeSync(file.fd, buf);
  } finally {
    if (file) try { fs.closeSync(file); } catch {}
  }

  return { elapsed, size: buf.byteLength, path: winner };
}



