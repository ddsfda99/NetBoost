import common from '@ohos.app.ability.common'
import { runBatch, Mode } from '../../common/Runner'
import { PerformanceMonitor, ModeStr } from '../../common/PerformanceMonitor'
import { NetworkNavigator } from '../navigator/NetworkNavigator'

@Entry
@Component
struct Index {
  // —— 可配置参数 —— //
  @State baseUrl: string = 'http://139.224.130.188/images'
  @State count: number = 50

  // —— 运行状态与输出 —— //
  @State running: boolean = false
  @State output: string = ''
  @State summary: string = ''

  // —— 运行模式 —— //
  @State mode: Mode = Mode.AUTO_SWITCH

  // —— 监控与挑战模块 —— //
  private pm: PerformanceMonitor = new PerformanceMonitor()
  private nav: NetworkNavigator = new NetworkNavigator()

  private appendLine(s: string) {
    this.output = (this.output ? this.output + '\n' : '') + s
  }

  private buildSummaryText(): string {
    const overall = this.pm.stats()
    const groups = this.pm.byMode()

    const lines: string[] = []
    lines.push('—— SUMMARY ——')
    lines.push(
      `rounds=${overall.rounds}  ` +
        `wall_avg=${overall.wall_avg.toFixed(3)}s  total_avg=${overall.total_avg.toFixed(3)}s  ` +
        `probe_pct≈${(overall.probe_pct * 100).toFixed(3)}%`
    )

    if (groups.WIFI_ONLY.n > 0 && groups.AUTO_SWITCH.n > 0) {
      const impAvg: number = PerformanceMonitor.improvementPct(groups.WIFI_ONLY.total_avg, groups.AUTO_SWITCH.total_avg)
      const impMed: number = PerformanceMonitor.improvementPct(groups.WIFI_ONLY.total_med, groups.AUTO_SWITCH.total_med)
      lines.push(`improve(totalTime): avg=${impAvg.toFixed(1)}%  med=${impMed.toFixed(1)}%`)
      lines.push(
        `consistency(sum(perFile.t)/totalTime): AUTO_SWITCH≈` +
          `${groups.AUTO_SWITCH.consistency_min.toFixed(1)}~${groups.AUTO_SWITCH.consistency_max.toFixed(1)}%`
      )
    }
    return lines.join('\n')
  }

  build() {
    Column() {
      Text('NetBoost — 弱网图片加载优化')
        .fontSize(22)
        .margin({ bottom: 16 })

      // —— Base URL —— //
      TextInput({ text: this.baseUrl, placeholder: 'Base URL（例如 http://<ip>/images）' })
        .onChange((v: string) => this.baseUrl = v)
        .margin({ bottom: 8 })

      // —— Count —— //
      TextInput({ text: String(this.count), placeholder: 'Count（例如 50）' })
        .type(InputType.Number)
        .onChange((v: string) => {
          const n: number = Number(v)
          if (!isNaN(n) && n > 0) this.count = n
        })
        .margin({ bottom: 12 })

      // —— 模式选择 —— //
      Row() {
        Button(this.mode === Mode.WIFI_ONLY ? '✓ Wi-Fi Only' : 'Wi-Fi Only')
          .onClick(() => this.mode = Mode.WIFI_ONLY)
          .margin({ right: 8 })

        Button(this.mode === Mode.AUTO_SWITCH ? '✓ Auto Switch' : 'Auto Switch')
          .onClick(() => this.mode = Mode.AUTO_SWITCH)
      }.margin({ bottom: 12 })

      // —— 控制区 —— //
      Row() {
        Button(this.running ? 'Running...' : 'Run ×5 (当前模式)')
          .enabled(!this.running)
          .onClick(async () => {
            this.running = true
            const lines: string[] = []
            const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext

            const toModeStr = (m: Mode): ModeStr => (m === Mode.WIFI_ONLY ? 'WIFI_ONLY' : 'AUTO_SWITCH')

            for (let i = 1; i <= 5; i++) {
              try {
                const r = await runBatch(this.baseUrl, this.count, this.mode, ctx)

                // 逐文件时长总和
                const sumPer: number = (r.perFile || []).reduce((acc: number, it) => acc + (it.t > 0 ? it.t : 0), 0)

                // 推送到性能监控聚合
                this.pm.push({
                  mode: toModeStr(this.mode),
                  wallTime: r.wallTime,
                  totalTime: r.totalTime,
                  pausedMs: r.pausedMs,
                  totalBytes: r.totalBytes,
                  sumPerFileTs: sumPer
                })

                lines.push(
                  `round=${i} mode=${toModeStr(this.mode)} ` +
                    `effective=${r.totalTime.toFixed(3)}s ` +
                    `wall=${r.wallTime.toFixed(3)}s ` +
                    `paused=${(r.pausedMs / 1000).toFixed(3)}s ` +
                    `bytes=${(r.totalBytes / 1048576).toFixed(2)}MB`
                )
              } catch (err) {
                lines.push(`round=${i} mode=${toModeStr(this.mode)} error=${err}`)
              }
            }

            this.appendLine(lines.join('\n'))
            this.summary = this.buildSummaryText()
            this.running = false
          })

        Button('Clear')
          .margin({ left: 8 })
          .enabled(!this.running)
          .onClick(() => { this.output = ''; this.summary = ''; this.pm.clear() })
      }
      .margin({ bottom: 12 })

      Column() {
        Row() {
          Text('Network Navigator（挑战项）').fontSize(16).opacity(0.9)
          Text(this.nav.isAvailable() ? '  [available]' : '  [unavailable]')
            .fontSize(12).opacity(0.6).margin({ left: 6 })
        }.margin({ bottom: 6 })

        Row() {
          Button('Simulate: Garage')
            .enabled(this.nav.isAvailable() && !this.running)
            .onClick(() => { this.nav.simulateGarage(); this.appendLine('[Navigator] simulate garage') })

          Button('Simulate: Leaving Home')
            .margin({ left: 8 })
            .enabled(this.nav.isAvailable() && !this.running)
            .onClick(() => { this.nav.simulateLeavingHome(); this.appendLine('[Navigator] simulate leaving_home') })

          Button('Stop')
            .margin({ left: 8 })
            .enabled(this.nav.isAvailable() && !this.running)
            .onClick(() => { this.nav.stopSimulation(); this.appendLine('[Navigator] stop') })
        }
      }
      .margin({ bottom: 12 })

      Text('提示：Auto Switch 模式下，弱网触发会引导切换；完成切换返回 App 将自动续传。')
        .fontSize(12).opacity(0.8).margin({ bottom: 8 })

      Text('Logs').fontSize(16).margin({ bottom: 6 })
      Scroll() {
        Text(this.output).fontFamily('monospace')
      }.height('38%').width('100%').margin({ bottom: 10 })

      if (this.summary) {
        Text('Summary').fontSize(16).margin({ bottom: 6 })
        Scroll() {
          Text(this.summary).fontFamily('monospace')
        }.height('18%').width('100%')
      }
    }
    .padding(16)
    .width('100%')
  }
}
