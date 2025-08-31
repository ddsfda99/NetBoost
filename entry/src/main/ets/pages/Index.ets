import http from '@ohos.net.http';
import connection from '@ohos.net.connection';
import { BusinessError } from '@ohos.base';

// —— 使用四个模块（注意 NetworkPredictor 这里一并导入 PredictorInput） —— //
import { NetworkSwitcher } from '../model/network/NetworkSwitcher';
import { NetworkPredictor, PredictorInput } from '../model/network/NetworkPredictor';
import { PerformanceMonitor, PerformanceReport } from '../model/performance/PerformanceMonitor';

// ===== 常量 =====
const DEFAULT_CONCURRENCY: number = 4;
const CONNECT_TIMEOUT_MS: number = 5000;
const READ_TIMEOUT_MS: number = 15000;

// ===== 显式类型 =====
interface DownloadResult {
  ok: boolean;
  bytes: number;
  durationMs: number;
  error?: string;
}
interface RunAllResult {
  results: Array<DownloadResult | undefined>;
  totalBytes: number;
}
interface RunStats {
  totalMs: number;
  totalBytes: number;
  successRate: number;
  avgKbps: number;
}

@Entry
struct Index {
  @State manifestUrl: string = 'http://192.168.1.78:8000/';
  @State logs: string[] = [];
  @State totalMs: number = 0;
  @State totalBytes: number = 0;
  @State running: boolean = false;

  @State preferCellular: boolean = false;
  @State predictiveMode: boolean = true;

  private wifiNet?: connection.NetHandle;
  private cellularNet?: connection.NetHandle;

  private switcher: NetworkSwitcher = new NetworkSwitcher();
  private predictor: NetworkPredictor = new NetworkPredictor();
  private perfMon: PerformanceMonitor = new PerformanceMonitor();

  private monitorCanceled: boolean = false;

  private lastBaselineReport?: PerformanceReport;
  private lastPredictReport?: PerformanceReport;
  private lastBaselineStats?: RunStats;
  private lastPredictStats?: RunStats;

  build(): void {
    Column({ space: 10 }) {
      Text('弱网图片加载实验（ArkTS 规范对齐版）')
        .fontSize(20).fontWeight(FontWeight.Bold)

      TextInput({ text: this.manifestUrl })
        .onChange((v: string) => this.manifestUrl = v)
        .width('100%')

      Row({ space: 12 }) {
        Toggle({ type: ToggleType.Switch, isOn: this.preferCellular })
          .onChange((v: boolean) => this.preferCellular = v)
        Text('手动偏好蜂窝（App 级切网）')

        Toggle({ type: ToggleType.Switch, isOn: this.predictiveMode })
          .onChange((v: boolean) => this.predictiveMode = v)
        Text('启用预测提前切换（EWMA）')
      }

      Row({ space: 12 }) {
        Button(this.running ? '运行中…' : '① 基线（默认路由）')
          .enabled(!this.running)
          .onClick(() => { void this.runOnce(false, 'baseline'); })
        Button(this.running ? '运行中…' : '② 预测切换（Wi-Fi→蜂窝）')
          .enabled(!this.running)
          .onClick(() => { void this.runOnce(true, 'predict'); })
        Button('清空日志').onClick(() => { this.logs = []; })
      }

      Text(`总耗时：${this.totalMs} ms    总字节：${this.totalBytes}`)

      Scroll() {
        Column() { ForEach(this.logs, (l: string) => Text(l).fontSize(12)) }
      }.height('55%')
    }.padding(16)
  }

  aboutToDisappear(): void { this.stopMonitor(); }

  // ===== 日志 =====
  private log(s: string): void {
    const ts: string = new Date().toLocaleTimeString();
    this.logs = [...this.logs, `${ts} ${s}`];
  }

  // ===== 扫描网络（getAllNets + getNetCapabilities） =====
  private async scanNets(): Promise<void> {
    const nets: Array<connection.NetHandle> = await connection.getAllNets();
    this.wifiNet = undefined;
    this.cellularNet = undefined;

    for (let i = 0; i < nets.length; i++) {
      const h: connection.NetHandle = nets[i];
      const caps: connection.NetCapabilities = await connection.getNetCapabilities(h);
      const bears: Array<connection.NetBearType> = caps.bearerTypes ?? [];
      if (bears.indexOf(connection.NetBearType.BEARER_WIFI) >= 0) this.wifiNet = h;
      if (bears.indexOf(connection.NetBearType.BEARER_CELLULAR) >= 0) this.cellularNet = h;
    }
    this.log(`发现网络：Wi-Fi=${Boolean(this.wifiNet)}，蜂窝=${Boolean(this.cellularNet)}`);
  }

  // ===== 预测监控（基于 1B Range GET） =====
  private startMonitor(): void {
    if (!this.predictiveMode) return;
    this.stopMonitor();
    this.monitorCanceled = false;
    this.predictor.reset();
    void this.runProbeLoop();
  }
  private stopMonitor(): void { this.monitorCanceled = true; }

  private async runProbeLoop(): Promise<void> {
    while (!this.monitorCanceled) {
      const t0: number = Date.now();
      const size: number = await this.rangePing(this.manifestUrl).catch(() => -1);
      const rttMs: number = Date.now() - t0;

      if (size >= 0) {
        const kbps: number = (size * 8) / Math.max(1, rttMs);

        // ⭐ 使用名义类型实例，避免 structural typing
        const sample = new PredictorInput(rttMs, kbps);
        const pred = this.predictor.update(sample);

        if (pred.willBeWeakNetwork && this.cellularNet) {
          this.log(`预测弱网（conf=${Math.round(pred.confidence * 100)}%）→ 提前切蜂窝（App 级绑定）`);
          await this.switcher.bindTo(this.cellularNet);
        }
      }
      // 节拍由 HTTP 往返自然决定
    }
  }

  /**
   * 1B Range GET 探测；事件/回调签名与官方一致：
   *  headersReceive(Object) / dataReceive(ArrayBuffer) / dataEnd(void)
   *  requestInStream(url, opts, (err: BusinessError, code: number) => void)
   */
  private async rangePing(url: string): Promise<number> {
    return new Promise<number>((resolve, reject) => {
      const req: http.HttpRequest = http.createHttp();
      let bytes: number = 0;
      let ended: boolean = false;

      const finish = (ok: boolean, err?: string): void => {
        if (ended) return;
        ended = true;
        try { req.destroy(); } catch {}
        if (ok) resolve(bytes); else reject(new Error(err ?? 'rangePing error'));
      };

      req.on('headersReceive', (_header: Object) => {});
      req.on('dataReceive', (ab: ArrayBuffer) => { bytes += ab.byteLength; });
      req.on('dataEnd', () => finish(true));

      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        connectTimeout: 3000,
        readTimeout: 3200,
        header: { 'Range': 'bytes=0-0' }
      };

      req.requestInStream(url, opts, (err: BusinessError, code: number) => {
        if (err) finish(false, err.message ?? `requestInStream error, code=${code}`);
        // 成功最终走 dataEnd
      });
    });
  }

  // ===== 解析清单：JSON 数组 / 目录 HTML =====
  private async getManifest(url: string): Promise<string[]> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const res: http.HttpResponse = await req.request(encodeURI(url), {
        method: http.RequestMethod.GET,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS
      });
      const raw: string = String(res.result ?? '');
      if (raw.length === 0) throw new Error('manifest empty');

      // 1) JSON 数组
      try {
        const parsed: Array<string> = JSON.parse(raw) as Array<string>;
        if (Array.isArray(parsed) && parsed.length > 0) {
          const list: string[] = [];
          for (let i = 0; i < parsed.length; i++) {
            const item: string = parsed[i];
            if (typeof item === 'string' && item.length > 0) list.push(encodeURI(item));
          }
          if (list.length > 0) {
            this.log(`✅ 解析 JSON 清单：${list.length} 条`);
            return list;
          }
        }
      } catch {
        // 继续尝试目录解析
      }

      // 2) 目录 HTML：提取图片链接（最多 50）
      const hrefs: string[] = [];
      const re: RegExp = /href="([^"]+)"/ig;
      let m: RegExpExecArray | null;
      while ((m = re.exec(raw)) !== null) {
        const href: string = m[1];
        if (/\.(jpg|jpeg|png|gif|bmp)$/i.test(href)) hrefs.push(href);
      }
      if (hrefs.length > 0) {
        const base: string = url.replace(/\/+$/, '');
        const out: string[] = [];
        const limit: number = Math.min(50, hrefs.length);
        for (let k = 0; k < limit; k++) {
          const h: string = hrefs[k];
          const full: string = /^https?:\/\//i.test(h) ? h : (base + (h.startsWith('/') ? h : '/' + h));
          out.push(encodeURI(full));
        }
        this.log(`✅ 解析目录页：抽到 ${out.length} 张图片`);
        return out;
      }

      throw new Error('manifest not parsable');
    } finally { req.destroy(); }
  }

  // ===== 单个下载（流式） =====
  private async downloadOne(url: string): Promise<DownloadResult> {
    return new Promise<DownloadResult>((resolve) => {
      const req: http.HttpRequest = http.createHttp();
      const t0: number = Date.now();
      let bytes: number = 0;
      let ended: boolean = false;

      const finish = (ok: boolean, err?: string): void => {
        if (ended) return;
        ended = true;
        const durationMs: number = Date.now() - t0;
        try { req.destroy(); } catch {}
        const res: DownloadResult = ok
          ? { ok: true, bytes, durationMs }
          : { ok: false, bytes: 0, durationMs, error: err };
        resolve(res);
      };

      req.on('headersReceive', (_header: Object) => {});
      req.on('dataReceive', (ab: ArrayBuffer) => { bytes += ab.byteLength; });
      req.on('dataEnd', () => finish(true));

      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS
      };

      req.requestInStream(url, opts, (err: BusinessError) => {
        if (err) finish(false, err.message ?? 'requestInStream error');
      });
    });
  }

  // ===== 并发下载器（队列调度） =====
  private async runConcurrent(urls: string[], concurrency: number): Promise<RunAllResult> {
    const total: number = urls.length;
    const results: Array<DownloadResult | undefined> = new Array<DownloadResult | undefined>(total);
    let nextIndex: number = 0;
    let inFlight: number = 0;
    let sumBytes: number = 0;

    return new Promise<RunAllResult>((resolve) => {
      const launchNext = (): void => {
        while (inFlight < concurrency && nextIndex < total) {
          const idx: number = nextIndex;
          nextIndex++;
          inFlight++;

          const url: string = urls[idx];
          void this.downloadOne(url).then((r: DownloadResult) => {
            results[idx] = r;
            if (r.ok) sumBytes += r.bytes;
          }).finally(() => {
            inFlight--;
            if (nextIndex >= total && inFlight === 0) {
              const out: RunAllResult = { results, totalBytes: sumBytes };
              resolve(out);
            } else {
              launchNext();
            }
          });
        }
      };
      launchNext();
    });
  }

  // ===== 一次完整测试 =====
  private async runOnce(enablePredict: boolean, tag: 'baseline' | 'predict'): Promise<void> {
    this.running = true;
    this.logs = [];
    this.totalBytes = 0;
    this.totalMs = 0;

    await this.scanNets();

    if (this.preferCellular && this.cellularNet) {
      await this.switcher.bindTo(this.cellularNet);
      this.log('已绑定到蜂窝网络（App 级）');
    } else {
      await this.switcher.bindToDefault();
      this.log('已绑定到默认网络（通常是 Wi-Fi）');
    }

    this.predictiveMode = enablePredict;
    if (this.predictiveMode) this.startMonitor();

    try {
      this.log(`GET 清单/目录：${this.manifestUrl}`);
      let urls: string[] = [];
      try {
        urls = await this.getManifest(this.manifestUrl);
      } catch (e) {
        const msg: string = (e as Error).message ?? 'manifest error';
        this.log(`❌ 清单获取失败：${msg}`);
        return;
      }
      if (urls.length === 0) { this.log('❌ 清单为空'); return; }

      const showN: number = Math.min(3, urls.length);
      for (let i = 0; i < showN; i++) this.log(`样例[${i + 1}]: ${urls[i]}`);

      const t0: number = Date.now();
      const runRes: RunAllResult = await this.runConcurrent(urls, DEFAULT_CONCURRENCY);
      this.totalMs = Date.now() - t0;
      this.totalBytes = runRes.totalBytes;

      let okCount: number = 0;
      for (let i = 0; i < runRes.results.length; i++) {
        const r = runRes.results[i];
        if (r && r.ok) { okCount++; this.log(`✅ [${i + 1}/${urls.length}] ${r.bytes} bytes`); }
        else this.log(`❌ [${i + 1}/${urls.length}] ${r?.error ?? 'unknown'}`);
      }

      this.log(`完成：总耗时=${this.totalMs} ms，总字节=${this.totalBytes}，成功=${okCount}/${urls.length}`);

      // 报告 + 关键指标
      let report: PerformanceReport;
      if (typeof this.perfMon.getPerformanceReport === 'function') {
        report = this.perfMon.getPerformanceReport();
      } else {
        report = {
          samples: 0,
          successCount: okCount,
          successRate: urls.length > 0 ? okCount / urls.length : 0,
          totalDurationMs: this.totalMs,
          totalBytes: this.totalBytes,
          avgThroughputKbps: this.totalMs > 0 ? (this.totalBytes * 8) / this.totalMs : 0,
          p50LatencyMs: 0, p90LatencyMs: 0, p99LatencyMs: 0
        } as PerformanceReport;
      }

      const stats: RunStats = {
        totalMs: this.totalMs,
        totalBytes: this.totalBytes,
        successRate: urls.length > 0 ? okCount / urls.length : 0,
        avgKbps: this.totalMs > 0 ? (this.totalBytes * 8) / this.totalMs : 0
      };

      if (tag === 'baseline') {
        this.lastBaselineReport = report;
        this.lastBaselineStats = stats;
      } else {
        this.lastPredictReport = report;
        this.lastPredictStats = stats;
      }

      if (this.lastBaselineStats && this.lastPredictStats) {
        const base = this.lastBaselineStats;
        const pred = this.lastPredictStats;

        const timeReduction: number = base.totalMs > 0 ? (base.totalMs - pred.totalMs) / base.totalMs : 0;
        const throughputImprovement: number = base.avgKbps > 0 ? (pred.avgKbps - base.avgKbps) / base.avgKbps : 0;
        const successRateImprovement: number = base.successRate > 0 ? (pred.successRate - base.successRate) / base.successRate : 0;

        this.log(`对比：时间缩短 ${(timeReduction * 100).toFixed(1)}% | 吞吐提升 ${(throughputImprovement * 100).toFixed(1)}% | 成功率提升 ${(successRateImprovement * 100).toFixed(1)}%`);
        this.log(`基线报告 bytes=${this.lastBaselineReport?.totalBytes ?? 0}；预测报告 bytes=${this.lastPredictReport?.totalBytes ?? 0}`);
      }
    } finally {
      this.stopMonitor();
      await this.switcher.bindToDefault();
      this.running = false;
    }
  }
}

export default Index;
