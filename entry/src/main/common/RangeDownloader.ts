/**
 * RangeDownloader.ts
 * - 断点续传（服务器支持 Accept-Ranges: bytes 时）
 * - 不支持则回退整文件下载
 */
import fs from '@ohos.file.fs';
import { head, downloadWhole, downloadRangeAppend } from './HttpDownloader';

export type RangeResult = {
  elapsed: number;
  size: number;       // 本次增量字节
  usedRange: boolean; // 是否使用了 Range
  retried: boolean;   // 是否发生过续传
};

function fileSize(path: string): number {
  try { const s = fs.statSync(path); return s.size; } catch { return 0; }
}

export async function downloadWithResume(url: string, dstPath: string): Promise<RangeResult> {
  const h = await head(url).catch(() => ({ ok: false, acceptRanges: false } as any));
  const supportRange = !!(h && h.acceptRanges);

  // 已有部分？
  const existed = fileSize(dstPath);
  if (!supportRange) {
    // 不支持 Range，整文件重拉
    const r = await downloadWhole(url, dstPath);
    return { elapsed: r.elapsed, size: r.size, usedRange: false, retried: existed > 0 };
  }

  const totalLen = h.contentLength ?? undefined;
  let offset = existed;
  let totalElapsed = 0;
  let totalAppended = 0;
  let first = true;

  // 若已有且小于等于总长，则续传；否则从 0 开始
  if (totalLen !== undefined && existed > totalLen) {
    try { fs.unlinkSync(dstPath); } catch {}
    offset = 0;
  }

  while (totalLen === undefined || offset < totalLen) {
    const end = undefined;
    const rr = await downloadRangeAppend(url, dstPath, offset, end);
    totalElapsed += rr.elapsed;
    totalAppended += rr.size;

    // 206为分块，200说明服务器忽略了Range
    if (rr.status === 200) {
      break;
    }

    offset += rr.size;
    first = false;

    if (rr.size <= 0) break;
  }

  return { elapsed: totalElapsed, size: totalAppended, usedRange: supportRange, retried: existed > 0 };
}
