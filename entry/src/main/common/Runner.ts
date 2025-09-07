/**
 * runBatch.ts
 *
 * 本模块封装了批量图片下载任务，并在下载过程中进行弱网检测与网络选择：
 *
 * 1. 下载模式：
 *    - WIFI_ONLY：始终通过 Wi-Fi 下载。
 *    - AUTO_SWITCH：前 10 张图片强制使用双路并发（Wi-Fi + 蜂窝），
 *                   后续图片根据弱网判定动态选择 Wi-Fi 或双路。
 *
 * 2. 弱网判定逻辑：
 *    - 基于文件下载速率（KB/s）进行移动窗口检测。
 *    - earlyAvg：早期均速（前 25% 文件平均速度）。
 *    - recentAvg：最近均速（最近 8 个文件的平均速度）。
 *    - 如果 recentAvg < earlyAvg * 0.3，则判定 Wi-Fi 掉速为弱网。
 *    - 判弱后启用双路；否则继续走 Wi-Fi。
 *
 * 3. 日志记录：
 *    - 每个文件下载结果记录为 PerFile：
 *         { url, t: 耗时秒, bytes: 文件大小字节, path: 'wifi'|'cell' }
 *    - 批次整体结果包含总耗时、总字节数、逐文件明细。
 *    - 自动写入 JSON 文件到应用沙箱目录 (context.filesDir)。
 *
 * 4. 应用场景：
 *    - 在弱网优化实验中模拟真实页面图片加载过程。
 *    - 对比不同模式（Wi-Fi only vs Auto Switch）下的下载时间与流量分布。
 *    - 输出日志可用于后续分析（Wi-Fi/蜂窝流量占比、首屏时间等）。
 *
 * 依赖：
 * - HttpDownloader.ts 提供的 download / downloadWithChoice
 * - @ohos.file.fs
 * - @ohos.app.ability.common 获取应用沙箱目录
 */

import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { download, downloadWithChoice } from './HttpDownloader';

// 只用WiFi（基线）和WiFi、蜂窝自动切换（优化）
export enum Mode {
  WIFI_ONLY = 'WIFI_ONLY',
  AUTO_SWITCH = 'AUTO_SWITCH',
}

// 单个文件下载结果的记录结构
type PerFile = { url: string; t: number; bytes: number; path?: 'wifi'|'cell' };

const WINDOW = 8;           // 速率移动窗口（文件级）
const DROP_RATIO = 0.3;     // 最近均速 < 早期均速的 30% 视为弱网
const DUAL_FIRST_N = 10;    // 前 N 张允许双路（首屏体验）

function kbps(bytes: number, sec: number) {
  return (bytes / 1024) / Math.max(0.001, sec);
}

function avg(arr: number[]): number {
  return arr.reduce((a, b) => a + b, 0) / Math.max(1, arr.length);
}

// runBatch 会批量下载一组图片文件，记录每个文件和整体的耗时与大小，并把结果保存为 JSON 日志文件。
export async function runBatch(
  baseUrl: string,
  count: number,
  mode: Mode,
  context: common.UIAbilityContext
): Promise<{ totalTime: number; totalBytes: number; perFile: PerFile[] }> {
  const urls: string[] = [];
  for (let i = 1; i <= count; i++) {
    const name = `img_${String(i).padStart(3, '0')}.jpg`;
    urls.push(`${baseUrl.replace(/\/$/, '')}/${name}`);
  }

  const perFile: PerFile[] = [];
  const totalStart = Date.now();
  let totalBytes = 0;

  // 应用沙箱目录
  const filesDir = context.filesDir;

  // 简易弱网判定：基于历史文件下载速度的移动窗口
  const speedHistory: number[] = []; // kB/s

  for (let i = 0; i < urls.length; i++) {
    const u = urls[i];
    const filename = u.split('/').pop() as string;
    const dst = `${filesDir}/${filename}`;

    // --- 选择策略 ---
    let choice: 'wifi' | 'dual' = 'wifi';
    if (mode === Mode.AUTO_SWITCH) {
      // 计算“早期均速”和“最近均速”
      const win = speedHistory.slice(-WINDOW);
      const early = speedHistory.slice(0, Math.max(1, Math.floor(speedHistory.length * 0.25)));
      const earlyAvg = early.length ? avg(early) : Infinity; // 刚开始时不要误判
      const recentAvg = win.length ? avg(win) : Infinity;

      const weakBySpeed = (isFinite(earlyAvg) && isFinite(recentAvg) && (recentAvg < earlyAvg * DROP_RATIO));
      const preferDual = weakBySpeed || (i < DUAL_FIRST_N); // 首屏先行：前 N 张尝试 dual

      choice = preferDual ? 'dual' : 'wifi';
    }

    try {
      if (mode === Mode.WIFI_ONLY) {
        const r = await download(u, dst);
        totalBytes += r.size;
        perFile.push({ url: u, t: r.elapsed, bytes: r.size, path: 'wifi' });
        speedHistory.push(kbps(r.size, r.elapsed));
      } else {
        const r = await downloadWithChoice(u, dst, choice);
        totalBytes += r.size;
        perFile.push({ url: u, t: r.elapsed, bytes: r.size, path: r.path });
        speedHistory.push(kbps(r.size, r.elapsed));
      }
    } catch (e) {
      console.error('Download error for', u, e);
      perFile.push({ url: u, t: -1, bytes: 0 });
      // 失败不记速率，避免污染窗口
    }
  }

  const totalTime = (Date.now() - totalStart) / 1000.0;
  const record = { ts: Date.now(), baseUrl, count, totalTime, totalBytes, perFile, mode };
  const logPath = `${filesDir}/netbench_${record.ts}_${mode}.json`;

  try {
    const fh = fs.openSync(logPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    fs.writeSync(fh.fd, JSON.stringify(record));
    fs.closeSync(fh.fd);
    console.info('Log saved to', logPath);
  } catch (err) {
    console.error('Failed to write log JSON:', err);
  }

  // === Mirror to public download dir (hdc-friendly) ===
  try {
    const pubDir = '/storage/Users/currentUser/Download/com.example.netboost';
    try { fs.mkdirSync(pubDir); } catch (_) { /* already exists */ }
    const pubPath = `${pubDir}/netbench_${record.ts}_${mode}.json`;

    const stat = fs.statSync(logPath);
    const buf = new ArrayBuffer(stat.size);
    const fh2 = fs.openSync(logPath, fs.OpenMode.READ_ONLY);
    fs.readSync(fh2.fd, buf, { offset: 0 });  // 读私有目录文件
    fs.closeSync(fh2);

    const out = fs.openSync(pubPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    fs.writeSync(out.fd, buf);                 // 写到公共下载目录
    fs.closeSync(out);

    console.info('Log mirrored to', pubPath);
  } catch (e) {
    console.error('Mirror to public dir failed:', e);
  }

  return { totalTime, totalBytes, perFile };
}
