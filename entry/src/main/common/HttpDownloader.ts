/**
 * HttpDownloader.ts
 * - 基础 HTTP 封装：HEAD / GET / Range GET
 * - 与文件系统配合：整文件写入、追加写入
 */
import http from '@ohos.net.http';
import fs from '@ohos.file.fs';
import { connection } from '@kit.NetworkKit';

export async function getDefaultNetId(): Promise<number> {
  try {
    const h = await connection.getDefaultNet();
    return (h && typeof (h as any).netId === 'number') ? (h as any).netId : 0;
  } catch { return 0; }
}

export type HeadInfo = {
  ok: boolean;
  status: number;
  headers: Record<string, string>;
  acceptRanges: boolean;
  contentLength?: number;
  etag?: string;
  lastModified?: string;
};

function lowerHeaders(h: any): Record<string, string> {
  const out: Record<string, string> = {};
  try {
    for (const k of Object.keys(h || {})) out[String(k).toLowerCase()] = String((h as any)[k]);
  } catch {}
  return out;
}

export async function head(url: string, timeoutMs = 15000): Promise<HeadInfo> {
  const req = http.createHttp();
  return new Promise((resolve) => {
    req.request(url, {
      method: http.RequestMethod.HEAD,
      connectTimeout: timeoutMs,
      readTimeout: timeoutMs,
      expectDataType: http.HttpDataType.STRING
    }, (err, data) => {
      let status = 0, headers: Record<string,string> = {};
      if (!err && data) { status = (data as any).responseCode; headers = lowerHeaders((data as any).header); }
      try { req.destroy(); } catch {}
      resolve({
        ok: !err && status >= 200 && status < 400,
        status,
        headers,
        acceptRanges: headers['accept-ranges'] === 'bytes',
        contentLength: headers['content-length'] ? Number(headers['content-length']) : undefined,
        etag: headers['etag'],
        lastModified: headers['last-modified']
      });
    });
  });
}

export async function downloadWhole(url: string, dstPath: string): Promise<{ elapsed: number; size: number }> {
  const req = http.createHttp();
  const start = Date.now();
  return new Promise((resolve, reject) => {
    req.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 60000,
      readTimeout: 600000,
    }, (err, data) => {
      const end = Date.now();
      if (err) { try { req.destroy(); } catch {}; return reject(err); }
      const arr = (data as any).result as ArrayBuffer;
      let fh: fs.File | undefined;
      try {
        fh = fs.openSync(dstPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
        fs.writeSync(fh.fd, arr);
        fs.closeSync(fh.fd);
      } catch (e) {
        if (fh) { try { fs.closeSync(fh); } catch {} }
        try { req.destroy(); } catch {}
        return reject(e);
      }
      try { req.destroy(); } catch {}
      resolve({ elapsed: (end - start) / 1000, size: arr.byteLength });
    });
  });
}

/** 追加写入 Range 请求（bytes=start-，可选 end） */
export async function downloadRangeAppend(
  url: string, dstPath: string, startByte: number, endByte?: number,
  timeouts = { connectMs: 15000, readMs: 600000 }
): Promise<{ elapsed: number; size: number; status: number; headers: Record<string,string> }> {
  const req = http.createHttp();
  const start = Date.now();
  const range = typeof endByte === 'number' ? `bytes=${startByte}-${endByte}` : `bytes=${startByte}-`;
  return new Promise((resolve, reject) => {
    req.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: timeouts.connectMs,
      readTimeout: timeouts.readMs,
      header: { 'Range': range }
    }, (err, data) => {
      const end = Date.now();
      if (err) { try { req.destroy(); } catch {}; return reject(err); }
      const arr = (data as any).result as ArrayBuffer;
      const status = (data as any).responseCode as number;
      const headers = lowerHeaders((data as any).header);
      let fh: fs.File | undefined;
      try {
        fh = fs.openSync(dstPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND);
        fs.writeSync(fh.fd, arr);
        fs.closeSync(fh.fd);
      } catch (e) {
        if (fh) { try { fs.closeSync(fh); } catch {} }
        try { req.destroy(); } catch {}
        return reject(e);
      }
      try { req.destroy(); } catch {}
      resolve({ elapsed: (end - start) / 1000, size: arr.byteLength, status, headers });
    });
  });
}

