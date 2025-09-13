/**
 * Runner.ts — 整合：判弱 + 并发调度 + 分阶段迁移 + 断点续传 + 轻探测
 * - 双口径：wallTime（含等待）、totalTime（剔等待）
 * - 日志：weak_detect_index / switch_trigger_ts / probes / perFile{path,used_range,retried}
 */
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';

import { PriorityPool } from './PriorityPool';
import { WeakNetDetector } from './WeakNetDetector';
import { getDefaultNetId } from './HttpDownloader';
import { downloadWithResume } from './RangeDownloader';
import { NetProbe } from './NetProbe';

export enum Mode { WIFI_ONLY = 'WIFI_ONLY', AUTO_SWITCH = 'AUTO_SWITCH' }

type PerFile = {
  url: string;
  t: number;             // 秒
  bytes: number;
  path?: 'wifi'|'cell';
  used_range?: boolean;
  retried?: boolean;
};

const CONC_BEFORE = 3;
const CONC_WEAK   = 2;
const CONC_AFTER  = 8;
const MAX_PROMPTS = 1;

const NET_POLL_INTERVAL = 1000;
const NET_POLL_TIMEOUT  = 120000;

function avg(a: number[]) { return a.reduce((x,y)=>x+y,0) / Math.max(1, a.length); }
function kbps(bytes: number, sec: number) { return (bytes / 1024) / Math.max(0.001, sec); }

async function waitForDefaultNetChange(prevNetId: number, timeoutMs = NET_POLL_TIMEOUT): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const cur = await getDefaultNetId();
    if (cur && cur !== prevNetId) return true;
    await new Promise(r => setTimeout(r, NET_POLL_INTERVAL));
  }
  return false;
}

async function openWifiSettings(ctx: common.UIAbilityContext): Promise<boolean> {
  const wants: any[] = [
    { action: 'ohos.settings.wifi' },
    { action: 'ohos.settings.action.wifi' },
    { action: 'ohos.settings.wireless' },
  ];
  for (const w of wants) { try { await ctx.startAbility(w); return true; } catch {} }
  return false;
}

function isSmallByName(u: string): boolean {
  const n = u.toLowerCase();
  if (n.includes('thumb') || n.includes('_s') || n.includes('_small') || n.endsWith('_128.jpg')) return true;
  const m = n.match(/img_(\d{3})\.jpg$/);
  if (m) { const idx = Number(m[1]); if (idx <= 16) return true; }
  return false;
}

export async function runBatch(
  baseUrl: string,
  count: number,
  mode: Mode,
  context: common.UIAbilityContext
): Promise<{ totalTime: number; totalBytes: number; perFile: PerFile[]; wallTime: number; pausedMs: number }> {

  // URL 列表
  const urls: string[] = [];
  for (let i = 1; i <= count; i++) {
    const name = `img_${String(i).padStart(3, '0')}.jpg`;
    urls.push(`${baseUrl.replace(/\/$/, '')}/${name}`);
  }
  const sampleUrl = urls[Math.min(0, urls.length - 1)] || `${baseUrl.replace(/\/$/, '')}/img_001.jpg`;

  const filesDir = (context as any).filesDir as string;
  const perFile: PerFile[] = Array(urls.length);
  const pool = new PriorityPool(CONC_BEFORE);
  const detector = new WeakNetDetector();
  const prober = new NetProbe(10);

  const wallStart = Date.now();
  let totalBytes = 0;
  let pausedMs = 0;

  let speeds: number[] = [];     // kB/s
  let promptsLeft = MAX_PROMPTS;
  let switched = false;
  let switching = false;
  let weakDetectIndex = -1;
  let switchTriggerTs = 0;

  function enqueue(i: number) {
    const u = urls[i];
    const filename = u.split('/').pop() as string;
    const dst = `${filesDir}/${filename}`;
    const smallHint = isSmallByName(u);

    pool.push(async () => {
      // 轻探测（低频），辅助预测；如已高风险则短期加速探测
      await prober.maybeProbe(i+1, u).catch(()=>{});

      const t0 = Date.now();
      try {
        const rr = await downloadWithResume(u, dst);
        const t = (Date.now() - t0) / 1000;
        totalBytes += rr.size;
        perFile[i] = { url: u, t, bytes: rr.size, path: switched ? 'cell' : 'wifi', used_range: rr.usedRange, retried: rr.retried };

        // 速率（以本次增量为准）
        const spd = kbps(rr.size, t);
        speeds.push(spd);

        // 判弱（仅在 AUTO_SWITCH 且未切换）
        if (mode === Mode.AUTO_SWITCH && !switched && !switching && promptsLeft > 0) {
          const d = detector.feed(spd, undefined, true);
          if (d.isWeak) {
            // 加速探测 15s
            if (d.confidence >= 0.5) prober.boostShort(15000);

            // —— 分阶段迁移 —— //
            switching = true;
            weakDetectIndex = i;
            switchTriggerTs = Date.now();

            // 降并发，让 small 收尾
            pool.setLimit(CONC_WEAK);
            await new Promise<void>(res => {
              const tick = () => {
                const s = pool.snapshot();
                if (s.smallQ === 0 && s.running <= CONC_WEAK) return res();
                setTimeout(tick, 100);
              };
              tick();
            });

            // 引导切换 & 统计等待
            const prevId = await getDefaultNetId();
            const pauseStart = Date.now();
            await openWifiSettings(context);
            await waitForDefaultNetChange(prevId);
            pausedMs += (Date.now() - pauseStart);

            // 抬升并发，标记后续为 'cell'
            switched = true;
            promptsLeft -= 1;
            pool.setLimit(CONC_AFTER);
            switching = false;
          }
        }
      } catch (e) {
        // 失败：标记并送入检测器（失败=0速率，ok=false）
        const t = (Date.now() - t0) / 1000;
        perFile[i] = { url: u, t: -1, bytes: 0, path: switched ? 'cell' : 'wifi' };
        detector.feed(0, undefined, false);
      }
    }, smallHint);
  }

  for (let i = 0; i < urls.length; i++) enqueue(i);
  await pool.idle();

  const wallTime = (Date.now() - wallStart) / 1000.0;
  const totalTime = Math.max(0, wallTime - pausedMs / 1000.0);

  // —— 写 JSON —— //
  const record = {
    ts: Date.now(),
    baseUrl, count, mode,
    wallTime, pausedMs, totalTime, totalBytes,
    perFile,
    weak_detect_index: weakDetectIndex,
    switch_trigger_ts: switchTriggerTs,
    scheduler: { before: CONC_BEFORE, weak: CONC_WEAK, after: CONC_AFTER },
    probes: prober.snapshot()
  };

  const logPath = `${filesDir}/netbench_${record.ts}_${mode}.json`;
  try {
    const fh = fs.openSync(logPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    fs.writeSync(fh.fd, JSON.stringify(record));
    fs.closeSync(fh.fd);
    console.info('[NetBench] Log saved', logPath);
  } catch (err) {
    console.error('[NetBench] write log failed:', err);
  }

  // 镜像到公共下载目录
  try {
    const pubDir = '/storage/Users/currentUser/Download/com.example.netboost';
    try { fs.mkdirSync(pubDir); } catch {}
    const pubPath = `${pubDir}/netbench_${record.ts}_${mode}.json`;
    const stat = fs.statSync(logPath);
    const buf = new ArrayBuffer(stat.size);
    const fh2 = fs.openSync(logPath, fs.OpenMode.READ_ONLY);
    fs.readSync(fh2.fd, buf, { offset: 0 }); fs.closeSync(fh2);
    const out = fs.openSync(pubPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    fs.writeSync(out.fd, buf); fs.closeSync(out);
    console.info('[NetBench] Log mirrored', pubPath);
  } catch (e) {
    console.error('[NetBench] mirror failed:', e);
  }

  return { totalTime, totalBytes, perFile, wallTime, pausedMs };
}
